import Hummingbird
import SayItProtocol

extension SayItHTTPServer {
    func registerPlaybackRoutes(on router: Router<BasicRequestContext>) {
        router.post("/v1/playback/play") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .playbackControl,
                command: .play
            )
        }
        router.post("/v1/playback/pause") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .playbackControl,
                command: .pause
            )
        }
        router.post("/v1/playback/clear") { request, _ in
            await self.authorizedCommand(
                request,
                scope: .playbackControl,
                command: .clear
            )
        }
        router.post("/v1/playback/seek") { request, _ in
            await self.authorizedDecodedCommand(
                request,
                scope: .playbackControl,
                body: SecondsRequest.self
            ) {
                .seek($0.seconds)
            }
        }
        router.post("/v1/playback/skip") { request, _ in
            await self.authorizedDecodedCommand(
                request,
                scope: .playbackControl,
                body: SecondsRequest.self
            ) {
                .skip($0.seconds)
            }
        }
        router.patch("/v1/playback/rate") { request, _ in
            await self.authorizedDecodedCommand(
                request,
                scope: .playbackControl,
                body: PlaybackRateRequest.self
            ) {
                .setPlaybackRate($0.rate)
            }
        }
    }
}
