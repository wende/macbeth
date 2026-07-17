# Releasing Macbeth

Macbeth has two build paths:

- Every push to `main` produces a short-lived, ad-hoc-signed GitHub Actions
  artifact for testing. It is not an end-user release and Gatekeeper may block
  it when downloaded through a browser.
- A `v*` tag runs the protected release workflow. It signs both universal
  binaries with Developer ID, submits their exact code hashes to Apple's notary
  service, publishes the npm tarball, and attaches the notarized archive to the
  GitHub release.

## One-time GitHub setup

Create a GitHub environment named `release` and protect it with required
reviewers. Configure these environment secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of the Developer ID Application identity exported as a password-protected `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password chosen while exporting that `.p12` |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_API_PRIVATE_KEY` | Complete contents of the downloaded `AuthKey_*.p8` file |

In Keychain Access, export only this identity, including its nested private key:

`Developer ID Application: Krzysztof Wende (5N28UN29Z6)`

To avoid placing secret values in shell history, use interactive `gh` input or
redirect files directly:

```sh
base64 < developer-id.p12 > developer-id.p12.base64
gh secret set MACOS_CERTIFICATE_P12 --env release < developer-id.p12.base64
gh secret set MACOS_CERTIFICATE_PASSWORD --env release
gh secret set APPLE_API_KEY_ID --env release
gh secret set APPLE_API_ISSUER_ID --env release
gh secret set APPLE_API_PRIVATE_KEY --env release < AuthKey_KEYID.p8
```

Delete the temporary `.p12` and base64 copy after the secrets are configured.

On npmjs.com, open the `macbeth` package settings and configure a GitHub
Actions trusted publisher with:

- Organization or user: `wende`
- Repository: `macbeth`
- Workflow filename: `release.yml`
- Environment name: `release`
- Allowed action: `npm publish`

The workflow uses npm's OIDC authentication, so no long-lived npm token or
`NPM_TOKEN` GitHub secret is needed.

## Publishing

Update `client/package.json` to the intended version, commit it, and push a
matching tag:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The workflow rejects a tag that does not exactly match the package version. It
also stops before publishing unless every signing and notarization secret is
present.
