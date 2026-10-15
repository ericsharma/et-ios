# Local patches to Citadel 0.12.1

Vendored from https://github.com/orlandos-nl/Citadel at tag 0.12.1 (MIT, see LICENSE).

1. `SSHClientSettings.loginTimeout` replaces the hardcoded 10 s login timeout.
2. `SSHClientSettings.onUserAuthBanner` receives SSH_MSG_USERAUTH_BANNER messages.
   After the first banner the timeout becomes `loginTimeoutAfterBanner` (default 5 min).

Why: Tailscale SSH in "check" mode holds the login, sends the approval URL as an
auth banner, and completes only after the user approves in a browser. Without
these, the URL is never seen and the login times out after 10 s.

Both changes are in `Sources/Citadel/ClientSession.swift` (search "E.T. patch").
Drop this fork if upstream adds equivalent options.
