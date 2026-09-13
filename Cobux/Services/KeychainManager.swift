import Foundation
import Security

struct KeychainManager {
    static let anthropicAPIKey = "anthropic_api_key"
    private static let service = "com.rajansharma.Cobux"

    /// The keychain access group the app AND its Messages extension can both
    /// read. Declared in `Cobux.entitlements` and `CobuxMessages.entitlements`
    /// as `$(AppIdentifierPrefix)com.rajansharma.Cobux.shared`; the runtime
    /// string has to spell the prefix out, because `kSecAttrAccessGroup` takes
    /// the resolved value and there is no public API on iOS that hands a
    /// process its own entitlement list. `58Q76NHADF` is `DEVELOPMENT_TEAM` in
    /// `project.yml` -- the one other place it appears. If the team ever
    /// changes, the entitlement follows automatically and this does not;
    /// `save` catches that case (`errSecMissingEntitlement`) and falls back to
    /// an unqualified write, so a stale prefix costs the extension the key but
    /// never costs the APP the key.
    ///
    /// Why a shared group at all: before build 58 nothing declared
    /// `keychain-access-groups`, so the key lived in the app's default group,
    /// `<TeamID>.com.rajansharma.Cobux`. A Messages extension is a separate
    /// process whose default group is `<TeamID>.com.rajansharma.Cobux.CobuxMessages`
    /// -- a different group -- and it could not read the key at all, which is
    /// the single hard stop `docs/imessage-journaling.md` §3 named for chat
    /// inside Messages. `AskCobuxIntent` never hit this because App Intents run
    /// inside the app's own process.
    static let sharedAccessGroup = "58Q76NHADF.com.rajansharma.Cobux.shared"

    /// `AfterFirstUnlock`, not `WhenUnlocked`.
    ///
    /// `AskCobuxIntent` runs in this process without the app coming to the
    /// foreground -- Siri from a locked phone is the whole point of it. Under
    /// `WhenUnlockedThisDeviceOnly` the load returned `nil` on a locked
    /// device, and the intent told a user whose key IS set to "Add your
    /// Anthropic API key in Cobux Settings". After-first-unlock is the
    /// standard class for a secret a background intent needs: readable any
    /// time after the first unlock since boot, never before, and still never
    /// migrated off this device (no iCloud Keychain, no backup restore onto
    /// another phone).
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Set once an existing item has been re-stamped with `accessibility`.
    /// Items written by builds before 52 carry `WhenUnlocked`; the class of a
    /// stored item cannot be read back, so a flag records that the one-time
    /// update ran rather than probing for it.
    private static let accessibilityMigratedKey = "cobux.keychain.accessibility.afterFirstUnlock"

    /// Writes INTO the shared group, explicitly.
    ///
    /// Apple's rule for an unqualified `SecItemAdd`: the item lands in the
    /// FIRST entry of `keychain-access-groups` when that entitlement is
    /// present, and in the app-identifier group when it is not. Build 58 adds
    /// the entitlement, so an unqualified write would silently change groups
    /// between builds -- which is exactly the "every existing user's key
    /// becomes unreadable" failure §3 warned about. Naming the group on every
    /// write, and reading the old group on every miss (`load`), is what makes
    /// the move safe: there is no build on which a key is written somewhere
    /// the next read does not look.
    @discardableResult
    static func save(key: String, data: String) -> Bool {
        guard let dataEncoded = data.data(using: .utf8) else {
            return false
        }

        // Unqualified: removes the item from EVERY group this process can
        // reach, so a re-save never leaves a stale twin behind in the old
        // app-identifier group for `load`'s fallback to find later.
        delete(key: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: dataEncoded,
            kSecAttrAccessible as String: accessibility,
            kSecAttrAccessGroup as String: sharedAccessGroup
        ]

        var status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            // Most often `errSecMissingEntitlement`: the group is not in this
            // build's entitlements (a signing profile that predates it, or a
            // changed team prefix). Any other failure is treated the same
            // way, because the `delete` above has already run and the only
            // thing worse than a key the extension cannot read is no key at
            // all. Storing it where only this process can read it keeps the
            // app working; only the extension goes without.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess {
            // Anything written from here on already carries the new class.
            UserDefaults.standard.set(true, forKey: accessibilityMigratedKey)
        }
        return status == errSecSuccess
    }

    /// Shared group first; the old, unqualified location second.
    ///
    /// The fallback is not a search of "the old group" by name -- an
    /// unqualified `SecItemCopyMatching` searches every group the calling
    /// process can access, and the app's own app-identifier group is always
    /// in that set whether or not `keychain-access-groups` is declared. So in
    /// the APP this finds the item every earlier build wrote, and the one time
    /// it does, the value is re-saved into the shared group and the old item
    /// removed (`save` deletes unqualified first). From then on the first
    /// query hits. In the EXTENSION the fallback can only see the extension's
    /// own group and the shared one, so an un-migrated key reads as missing
    /// there until the app has been opened once on this build -- which
    /// `migrateAccessibilityIfNeeded` (called at every app launch) guarantees
    /// by performing exactly this load.
    static func load(key: String) -> String? {
        if let value = read(key: key, accessGroup: sharedAccessGroup) {
            return value
        }
        guard let legacy = read(key: key, accessGroup: nil) else {
            return nil
        }
        // Found at the pre-58 location. Move it. `save` deletes first and
        // adds second, and falls back to an unqualified add if the shared
        // one is refused, so the worst outcome of this line is the key
        // staying exactly where it was -- and the legacy value is returned
        // regardless, so a user never sees "add your key" because a
        // migration hiccupped.
        save(key: key, data: legacy)
        return legacy
    }

    private static func read(key: String, accessGroup: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Unqualified on purpose: with no `kSecAttrAccessGroup` the delete
    /// applies to every matching item in every group this process can reach
    /// -- the shared group AND the old app-identifier group -- so "delete the
    /// key" means the key is gone, not gone from one of its two homes.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// One-time, on the first launch of a build that stores the key
    /// after-first-unlock: re-stamps an item written by an older build with
    /// the new accessibility class, in place, so current users' Siri requests
    /// start working without re-entering anything.
    ///
    /// Called from the foreground (the device is unlocked, so the old
    /// `WhenUnlocked` item is readable). `SecItemUpdate` changes the
    /// attribute without touching the value; if the update fails for any
    /// reason the flag stays unset and the next launch tries again. A device
    /// with no key stored has nothing to migrate and records that as done.
    ///
    /// Since build 58 this ALSO moves the key into the shared access group,
    /// every launch, by the simplest possible means: a `load`, whose miss
    /// path does the move. Deliberately not flag-gated -- the check is two
    /// keychain reads, the second only on a miss, and "the app has been
    /// opened once on this build" is the one guarantee the Messages extension
    /// needs before it can read the key at all. Runs where it already ran
    /// (`ContentView`'s startup task), so no call site changed.
    static func migrateAccessibilityIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: accessibilityMigratedKey) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: anthropicAPIKey
            ]
            let update: [String: Any] = [
                kSecAttrAccessible as String: accessibility
            ]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                defaults.set(true, forKey: accessibilityMigratedKey)
            }
        }
        // Order matters: the accessibility re-stamp above runs on the OLD
        // item in place, and the group move below then carries the re-stamped
        // value across. The other way round, `save` would write the shared
        // copy with the right class anyway -- but the unqualified
        // `SecItemUpdate` would then find and re-stamp the shared item, which
        // is harmless, only pointless.
        _ = load(key: anthropicAPIKey)
    }
}
