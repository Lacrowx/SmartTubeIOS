#if os(tvOS)
import AVKit
import SmartTubeIOSCore
import SwiftUI
import os

private let nativeLog = CrashlyticsLogger(category: "NativePlayer")

// MARK: - TVNativePlayerState

/// Everything the system player's menus, markers and info panel show. Read in the SwiftUI
/// body (so observation picks up changes) and handed to the representable as plain values.
struct TVNativePlayerState: Equatable {
    var formats: [VideoFormat]
    var selectedFormatID: UUID?
    var audioTracks: [AudioTrack]
    var selectedAudioID: String?
    /// The item has an HLS audio group, so Apple's own Audio menu already lists the languages.
    var systemAudioMenuListsTracks: Bool
    var captions: [CaptionTrack]
    var selectedCaptionID: String?
    var chapters: [Chapter]
    var skipSegment: SponsorSegment?
    var hasNext: Bool
    var hasPrevious: Bool
    var statsVisible: Bool
    var description: String
    var likeStatus: LikeStatus
    var sleepTimerMinutes: Int?
    var audioOnly: Bool
    /// `nil` when the video isn't played from the queue (no shuffle to toggle).
    var queueShuffle: Bool?
    var hasChannel: Bool

    @MainActor init(vm: PlaybackViewModel, video: Video, settings: AppSettings) {
        formats = vm.availableFormats
        selectedFormatID = vm.selectedFormat?.id
        audioTracks = vm.availableAudioTracks
        selectedAudioID = vm.selectedAudioTrack?.id
        systemAudioMenuListsTracks = vm.audioManager.audioSelectionGroup != nil
        captions = vm.availableCaptions
        selectedCaptionID = vm.selectedCaption?.id
        chapters = vm.chapters
        skipSegment = vm.currentToastSegment
        hasNext = vm.hasNext
        hasPrevious = vm.hasPrevious
        statsVisible = vm.statsForNerdsVisible
        let current = vm.playerInfo?.video ?? video
        description = current.description ?? ""
        likeStatus = vm.likeStatus
        sleepTimerMinutes = vm.sleepTimerMinutes
        audioOnly = vm.isAudioOnlyMode
        queueShuffle = current.playlistId == CurrentQueueStore.playlistID ? settings.queueShuffleEnabled : nil
        hasChannel = (current.channelId ?? video.channelId)?.isEmpty == false
    }
}

/// What the "More" menu does outside the view model (settings, navigation).
struct TVNativePlayerActions {
    var toggleAudioOnly: () -> Void
    var toggleQueueShuffle: () -> Void
    var openChannel: () -> Void
}

// MARK: - TVNativePlayerView

/// Apple's player (AVPlayerViewController) around the view model's AVPlayer. Decoding, stream
/// selection and the HLS proxies are untouched; only the controls change.
struct TVNativePlayerView: UIViewControllerRepresentable {
    let vm: PlaybackViewModel
    let state: TVNativePlayerState
    let actions: TVNativePlayerActions
    /// Shown (thumbnail + title) until the first item exists.
    let video: Video

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = vm.player
        // AVKit's play/pause must not look like a stall to the view model (it would resume).
        vm.transportIsSystemOwned = true
        // PlayerDisplayMatcher owns Match Content and the HDR10 setting.
        controller.appliesPreferredDisplayCriteriaAutomatically = false

        // Captions, the loading placeholder and stats sit under the transport bar.
        let overlay = UIHostingController(
            rootView: TVNativeContentOverlay(vm: vm, model: context.coordinator.overlayModel, video: video))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        overlay.view.translatesAutoresizingMaskIntoConstraints = false
        if let content = controller.contentOverlayView {
            controller.addChild(overlay)
            content.addSubview(overlay.view)
            NSLayoutConstraint.activate([
                overlay.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                overlay.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                overlay.view.topAnchor.constraint(equalTo: content.topAnchor),
                overlay.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            overlay.didMove(toParent: controller)
        }

        context.coordinator.attach(controller: controller, player: vm.player)
        #if DEBUG
        PlaybackDiagnosticsDump.schedule(vm: vm)
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.apply(state, vm: vm, actions: actions)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.vm?.transportIsSystemOwned = false
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        let overlayModel = TVNativeOverlayModel()
        fileprivate(set) weak var vm: PlaybackViewModel?
        private weak var controller: AVPlayerViewController?
        private weak var player: AVPlayer?
        private var itemObservation: NSKeyValueObservation?
        private var lastState: TVNativePlayerState?
        private var actions: TVNativePlayerActions?
        private var displayID: ObjectIdentifier?
        private var subtitleCheck: Task<Void, Never>?

        func attach(controller: AVPlayerViewController, player: AVPlayer) {
            self.controller = controller
            self.player = player
            displayID = ObjectIdentifier(controller)
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.itemChanged() }
            }
        }

        func detach() {
            itemObservation = nil
            subtitleCheck?.cancel()
            if let displayID { PlayerDisplayMatcher.shared.release(displayID) }
        }

        func apply(_ state: TVNativePlayerState, vm: PlaybackViewModel, actions: TVNativePlayerActions) {
            self.vm = vm
            self.actions = actions
            reportDisplay()
            guard state != lastState, let controller else { return }
            let previous = lastState
            lastState = state

            rebuildMenus()
            controller.contextualActions = skipActions(for: state, vm: vm)
            if controller.customInfoViewControllers.isEmpty || previous?.description != state.description {
                controller.customInfoViewControllers = infoControllers(for: state, vm: vm)
            }
            if previous?.chapters != state.chapters {
                applyChapters(state.chapters, to: player?.currentItem)
            }
        }

        private func itemChanged() {
            let item = player?.currentItem
            if item != nil { overlayModel.hadItem = true }
            reportDisplay()
            if let lastState { applyChapters(lastState.chapters, to: item) }
            checkSubtitles(of: item)
        }

        /// Apple's Subtitles menu lists the item's subtitle renditions (YouTube's HLS has them).
        /// When there are some, the app's own Captions menu and captions step aside.
        private func checkSubtitles(of item: AVPlayerItem?) {
            subtitleCheck?.cancel()
            overlayModel.itemHasSubtitles = false
            rebuildMenus()
            guard let asset = item?.asset else { return }
            subtitleCheck = Task { [weak self] in
                let group = try? await asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled, let self else { return }
                self.overlayModel.itemHasSubtitles = group?.options.isEmpty == false
                self.rebuildMenus()
            }
        }

        private func reportDisplay() {
            guard let controller, let window = controller.view.window, let displayID else { return }
            PlayerDisplayMatcher.shared.show(player?.currentItem?.asset, in: window, from: displayID)
        }

        private func rebuildMenus() {
            guard let controller, let vm, let lastState, let actions else { return }
            controller.transportBarCustomMenuItems = menuItems(for: lastState, vm: vm, actions: actions)
        }

        // MARK: Transport bar menus

        private func menuItems(
            for state: TVNativePlayerState, vm: PlaybackViewModel, actions: TVNativePlayerActions
        ) -> [UIMenuElement] {
            var items: [UIMenuElement] = []
            if state.hasPrevious {
                items.append(
                    UIAction(title: "Previous Video", image: UIImage(systemName: AppSymbol.previousTrack)) { _ in
                        vm.playPrevious()
                    })
            }
            if state.hasNext {
                items.append(
                    UIAction(title: "Next Video", image: UIImage(systemName: AppSymbol.nextTrack)) { _ in
                        vm.playNext()
                    })
            }
            if let captions = captionsMenu(for: state, vm: vm) { items.append(captions) }
            if let audio = audioLanguageMenu(for: state, vm: vm) { items.append(audio) }
            if let quality = qualityMenu(for: state, vm: vm) { items.append(quality) }
            items.append(moreMenu(for: state, vm: vm, actions: actions))
            return items
        }

        private func captionsMenu(for state: TVNativePlayerState, vm: PlaybackViewModel) -> UIMenu? {
            guard !state.captions.isEmpty, !overlayModel.itemHasSubtitles else { return nil }
            let off = UIAction(title: "Off", state: state.selectedCaptionID == nil ? .on : .off) { _ in
                vm.selectCaption(nil)
            }
            let tracks = state.captions.map { track in
                UIAction(
                    title: track.isAutoGenerated ? "\(track.name) (auto)" : track.name,
                    state: track.id == state.selectedCaptionID ? .on : .off
                ) { _ in vm.selectCaption(track) }
            }
            return UIMenu(
                title: "Captions", image: UIImage(systemName: AppSymbol.captions), options: .singleSelection,
                children: [off] + tracks)
        }

        /// Only when Apple's Audio menu can't list the languages (YouTube's per-language variant
        /// streams); otherwise there would be two audio menus.
        private func audioLanguageMenu(for state: TVNativePlayerState, vm: PlaybackViewModel) -> UIMenu? {
            guard state.audioTracks.count > 1, !state.systemAudioMenuListsTracks else { return nil }
            let tracks = state.audioTracks.sortedForPicker().map { track in
                UIAction(
                    title: track.isOriginal ? "\(track.name) (Original)" : track.name,
                    state: track.id == state.selectedAudioID ? .on : .off
                ) { _ in vm.selectAudioTrack(track) }
            }
            return UIMenu(
                title: "Audio Language", image: UIImage(systemName: AppSymbol.audioLanguage),
                options: .singleSelection, children: tracks)
        }

        private func qualityMenu(for state: TVNativePlayerState, vm: PlaybackViewModel) -> UIMenu? {
            guard !state.formats.isEmpty else { return nil }
            let auto = UIAction(title: "Auto", state: state.selectedFormatID == nil ? .on : .off) { _ in
                vm.selectFormat(nil)
            }
            let formats = state.formats.map { format in
                UIAction(title: format.qualityLabel, state: format.id == state.selectedFormatID ? .on : .off) { _ in
                    vm.selectFormat(format)
                }
            }
            return UIMenu(
                title: "Quality", image: UIImage(systemName: AppSymbol.quality), options: .singleSelection,
                children: [auto] + formats)
        }

        private func moreMenu(
            for state: TVNativePlayerState, vm: PlaybackViewModel, actions: TVNativePlayerActions
        ) -> UIMenu {
            var children: [UIMenuElement] = [
                UIAction(
                    title: state.likeStatus == .like ? "Liked" : "Like", image: UIImage(systemName: AppSymbol.thumbsUp),
                    state: state.likeStatus == .like ? .on : .off
                ) { _ in vm.like() },
                UIAction(
                    title: state.likeStatus == .dislike ? "Disliked" : "Dislike",
                    image: UIImage(systemName: AppSymbol.thumbsDown), state: state.likeStatus == .dislike ? .on : .off
                ) { _ in vm.dislike() },
            ]
            if state.hasChannel {
                children.append(
                    UIAction(title: "Go to Channel", image: UIImage(systemName: AppSymbol.personCircle)) { _ in
                        actions.openChannel()
                    })
            }
            let sleepOff = UIAction(title: "Off", state: state.sleepTimerMinutes == nil ? .on : .off) { _ in
                vm.setSleepTimer(minutes: nil)
            }
            let sleepOptions = PlaybackViewModel.sleepTimerOptions.map { minutes in
                UIAction(title: "\(minutes) min", state: state.sleepTimerMinutes == minutes ? .on : .off) { _ in
                    vm.setSleepTimer(minutes: minutes)
                }
            }
            children.append(
                UIMenu(
                    title: "Sleep Timer", image: UIImage(systemName: AppSymbol.sleepTimer), options: .singleSelection,
                    children: [sleepOff] + sleepOptions))
            children.append(
                UIAction(
                    title: "Audio Only", image: UIImage(systemName: AppSymbol.audioOnly),
                    state: state.audioOnly ? .on : .off
                ) { _ in actions.toggleAudioOnly() })
            if let shuffle = state.queueShuffle {
                children.append(
                    UIAction(
                        title: "Shuffle Queue", image: UIImage(systemName: AppSymbol.shuffle), state: shuffle ? .on : .off
                    ) { _ in actions.toggleQueueShuffle() })
            }
            children.append(
                UIAction(
                    title: "Stats for Nerds", image: UIImage(systemName: AppSymbol.stats),
                    state: state.statsVisible ? .on : .off
                ) { _ in vm.toggleStatsForNerds() })
            return UIMenu(title: "More", image: UIImage(systemName: AppSymbol.more), children: children)
        }

        // MARK: SponsorBlock

        /// Apple's on-screen action button while a "show Skip button" segment plays. Auto-skip
        /// segments are handled by the view model as before.
        private func skipActions(for state: TVNativePlayerState, vm: PlaybackViewModel) -> [UIAction] {
            guard state.skipSegment != nil else { return [] }
            return [UIAction(title: "Skip") { _ in vm.skipToastSegment() }]
        }

        // MARK: Info panel

        private func infoControllers(for state: TVNativePlayerState, vm: PlaybackViewModel) -> [UIViewController] {
            var controllers: [UIViewController] = []
            if !state.description.isEmpty {
                let description = UIHostingController(rootView: TVNativeDescriptionView(text: state.description))
                description.title = "Description"
                controllers.append(description)
            }
            let comments = UIHostingController(rootView: TVNativeCommentsView(vm: vm))
            comments.title = "Comments"
            controllers.append(comments)
            for controller in controllers {
                controller.view.backgroundColor = .clear
                controller.preferredContentSize = CGSize(width: 1920, height: TVNativeInfoPanel.height)
            }
            return controllers
        }

        // MARK: Chapters

        private func applyChapters(_ chapters: [Chapter], to item: AVPlayerItem?) {
            guard let item else { return }
            let duration = item.duration.isNumeric ? item.duration.seconds : nil
            let sorted = chapters.sorted { $0.startTime < $1.startTime }
            let markers: [AVTimedMetadataGroup] = sorted.enumerated().map { index, chapter in
                let end = index + 1 < sorted.count ? sorted[index + 1].startTime : (duration ?? chapter.startTime + 1)
                let title = AVMutableMetadataItem()
                title.identifier = .commonIdentifierTitle
                title.value = chapter.title as NSString
                title.extendedLanguageTag = "und"
                let range = CMTimeRange(
                    start: CMTime(seconds: chapter.startTime, preferredTimescale: 600),
                    end: CMTime(seconds: max(end, chapter.startTime + 1), preferredTimescale: 600))
                return AVTimedMetadataGroup(items: [title], timeRange: range)
            }
            item.navigationMarkerGroups =
                markers.isEmpty ? [] : [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
            nativeLog.notice("[native] chapters=\(markers.count)")
        }
    }
}

// MARK: - Content overlay

/// What the content overlay needs from AVKit that the view model doesn't track.
@MainActor @Observable
final class TVNativeOverlayModel {
    /// The player has had an item: the loading placeholder (thumbnail + title) is done.
    var hadItem = false
    /// The current item has subtitle renditions, shown by Apple's Subtitles menu instead of
    /// the app's own captions.
    var itemHasSubtitles = false
}

private enum TVNativeInfoPanel {
    static let height: CGFloat = 400
}

/// Drawn in AVPlayerViewController's contentOverlayView: under the transport bar, over the video.
private struct TVNativeContentOverlay: View {
    let vm: PlaybackViewModel
    let model: TVNativeOverlayModel
    let video: Video

    var body: some View {
        ZStack {
            // Until the first item: the video's thumbnail and title. AVKit draws the only spinner
            // (it shows one even before the player has an item).
            if !model.hadItem {
                loadingPlaceholder
            }
            if let error = vm.error {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            if let cue = vm.currentCaptionCue, !model.itemHasSubtitles {
                CaptionCueView(text: cue.text)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            if vm.statsForNerdsVisible {
                StatsForNerdsOverlay(snapshot: vm.statsSnapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingPlaceholder: some View {
        ZStack {
            // The feed's thumbnail is already cached and shows at once; the 1280×720 one
            // replaces it when it arrives.
            ZStack {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.black
                }
                TVNativeHighResThumbnail(
                    urls: [video.maxResThumbnailURL].compactMap { $0 } + video.highResThumbnailFallbackURLs)
            }
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
            let title = vm.playerInfo?.video.title ?? video.title
            if !title.isEmpty {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 1200)
                    .padding(.top, 220)  // below AVKit's centred spinner
            }
        }
    }
}

/// Tries `urls` in order (maxresdefault 404s for videos not uploaded in HD) and shows the first
/// that loads; nothing until then.
private struct TVNativeHighResThumbnail: View {
    let urls: [URL]
    @State private var index = 0

    var body: some View {
        if index < urls.count {
            AsyncImage(url: urls[index]) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.clear.onAppear { index += 1 }
                default:
                    Color.clear
                }
            }
        }
    }
}

// MARK: - Info panel tabs

private struct TVNativeDescriptionView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(40)
        }
        .frame(height: TVNativeInfoPanel.height)
        .clipped()
        .focusable()
    }
}

/// Top-level comments, loaded the first time the tab is shown.
private struct TVNativeCommentsView: View {
    let vm: PlaybackViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if vm.comments.isLoading && vm.comments.comments.isEmpty {
                    ProgressView()
                } else if vm.comments.comments.isEmpty {
                    Text("No comments")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.comments.comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(comment.author)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(comment.text)
                            .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(40)
        }
        .frame(height: TVNativeInfoPanel.height)
        .clipped()
        .focusable()
        .onAppear {
            if let id = vm.currentVideo?.id { vm.comments.load(videoId: id) }
        }
    }
}
// MARK: - PlayerView wiring

extension PlayerView {
    /// Apple's player for the current video; replaces the custom overlay unless Settings →
    /// Classic Player is on.
    var nativePlayer: some View {
        TVNativePlayerView(
            vm: vm,
            state: TVNativePlayerState(vm: vm, video: video, settings: store.settings),
            actions: TVNativePlayerActions(
                toggleAudioOnly: {
                    vm.toggleAudioOnlyLive()
                    store.settings.audioOnlyMode = vm.isAudioOnlyMode
                },
                toggleQueueShuffle: { store.settings.queueShuffleEnabled.toggle() },
                openChannel: {
                    let channelId = vm.playerInfo?.video.channelId ?? video.channelId
                    if let channelId, !channelId.isEmpty {
                        channelDestination = ChannelDestination(channelId: channelId)
                    }
                }
            ),
            video: video
        )
    }
}
#endif
