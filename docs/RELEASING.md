# Releasing pgdata Packer

How a release is built, signed with a Developer ID, notarized by Apple, and published. The
one-time setup needs an Apple Developer Program membership; without it, `make-app.sh` still builds
an ad-hoc signed app that opens on the Mac that built it and makes other Macs show a security
warning.

## One-time setup

1. **Enrol in the Apple Developer Program** at developer.apple.com/programs/enroll. Enrolling as an
   individual puts your own name on the signing certificate ("Developer ID Application: Your Name
   (TEAMID)"); enrolling as an organization needs a legal entity with a D-U-N-S number and puts the
   organization's name there. The fee is US$99 a year (confirm the current figure on the page).
   Approval is not immediate; it can take a few days.
2. **Create a Developer ID Application certificate.** With Xcode: Settings → Accounts → add your
   Apple ID → Manage Certificates → "+" → Developer ID Application. Without Xcode: in Keychain
   Access choose Certificate Assistant → Request a Certificate From a Certificate Authority (saved
   to disk), upload that request at developer.apple.com/account/resources/certificates ("+" →
   Developer ID Application), download the certificate, and double-click it. Either way, this
   command then lists the identity to pass to `make-app.sh --sign`:

   ```
   security find-identity -v -p codesigning
   ```

3. **Store notarization credentials** in the keychain, under the profile name the script uses.
   You need an app-specific password (account.apple.com → Sign-In and Security → App-Specific
   Passwords) and your Team ID (developer.apple.com/account → Membership details):

   ```
   xcrun notarytool store-credentials "pgdata-packer" --apple-id you@example.com --team-id TEAMID
   ```

   It asks for the app-specific password and keeps everything in the keychain; nothing goes into
   the repository.

## Each release

1. Set `VERSION` in `make-app.sh` and write the release notes.
2. Build, sign, notarize, staple, and zip in one go:

   ```
   ./make-app.sh --universal --sign "Developer ID Application: Your Name (TEAMID)" --notarize --zip
   ```

   The script signs with the hardened runtime and a secure timestamp, submits the app and waits
   for Apple's verdict (usually a few minutes), staples the ticket to the app, and only then
   writes `pgdata-Packer-<version>.zip`. If notarization is refused, the error names the
   submission id; `xcrun notarytool log <id> --keychain-profile "pgdata-packer"` gives the
   reasons.
3. Check the result as another Mac would see it:

   ```
   spctl --assess --type execute --verbose=2 "pgdata Packer.app"
   ```

   should end in `accepted` with `source=Notarized Developer ID`.
4. Tag the commit, create the GitHub release with the notes, and attach the zip. At the first
   signed release, the README's Build section gains a Download paragraph.

The build number in `Info.plist` (`CFBundleVersion`) is the repository's commit count, so it rises
with every release; an in-app updater, if one is added later, compares it.
