import Foundation

/// Allowlist and descriptions derived from simslim (MIT, Copyright 2026 Interlap).
enum ServiceCatalog {
  static let categories: [SlimCategory] = [
    .init(
      id: "widgets", name: "Widgets & Wallpaper",
      description: "Home and lock screen posters, widgets, and Live Activities.",
      downside:
        "Home and Lock Screen widgets, wallpaper posters, and Live Activities stop updating.",
      approxMemoryMB: 675,
      labels: ["com.apple.PosterBoard", "com.apple.chronod", "com.apple.liveactivitiesd"],
      serviceDescriptions: [
        "com.apple.PosterBoard": "Renders Home and Lock Screen wallpaper scenes.",
        "com.apple.chronod": "Refreshes widgets and complications on schedule.",
        "com.apple.liveactivitiesd": "Updates Live Activities and Dynamic Island content.",
      ], alwaysEnabled: []),
    .init(
      id: "siri", name: "Siri & Intelligence",
      description: "Siri, Apple Intelligence, speech, and on-device ML model services.",
      downside: "Siri, speech features, and Apple Intelligence services are unavailable.",
      approxMemoryMB: 265,
      labels: [
        "com.apple.assistantd", "com.apple.assistant_cdmd", "com.apple.assistant_service",
        "com.apple.siriactionsd", "com.apple.siriinferenced", "com.apple.siriknowledged",
        "com.apple.sirittsd", "com.apple.siri.context.service", "com.apple.siri.acousticsignature",
        "com.apple.corespeechd", "com.apple.voiced", "com.apple.voicebankingd",
        "com.apple.speechmodeltrainingd", "com.apple.intelligenceplatformd",
        "com.apple.intelligencecontextd", "com.apple.intelligenceflowd",
        "com.apple.intelligencetasksd", "com.apple.generativeexperiencesd",
        "com.apple.knowledgeconstructiond", "com.apple.naturallanguaged",
        "com.apple.textunderstandingd", "com.apple.modelcatalogd", "com.apple.modelmanagerd",
        "com.apple.mlhostd", "com.apple.mlruntimed", "com.apple.suggestd", "com.apple.parsecd",
        "com.apple.parsec-fbf", "com.apple.proactiveeventtrackerd",
      ],
      serviceDescriptions: [
        "com.apple.assistant_cdmd": "Routes commands and intents submitted to Siri.",
        "com.apple.assistant_service": "Provides supporting services for Siri requests.",
        "com.apple.assistantd": "Coordinates Siri requests and assistant state.",
        "com.apple.corespeechd": "Provides speech recognition and voice-trigger services.",
        "com.apple.generativeexperiencesd": "Supports generative intelligence experiences.",
        "com.apple.intelligencecontextd": "Collects local context for intelligence features.",
        "com.apple.intelligenceflowd": "Orchestrates Apple Intelligence workflows.",
        "com.apple.intelligenceplatformd": "Coordinates Apple Intelligence services.",
        "com.apple.intelligencetasksd": "Runs background Apple Intelligence tasks.",
        "com.apple.knowledgeconstructiond": "Builds on-device knowledge used by suggestions.",
        "com.apple.mlhostd": "Hosts system machine-learning services.",
        "com.apple.mlruntimed": "Executes on-device machine-learning models.",
        "com.apple.modelcatalogd": "Tracks machine-learning models available to the system.",
        "com.apple.modelmanagerd": "Downloads and manages on-device models.",
        "com.apple.naturallanguaged": "Performs natural-language analysis.",
        "com.apple.parsec-fbf": "Collects feedback for Siri and Spotlight suggestions.",
        "com.apple.parsecd": "Provides network-backed Siri and Spotlight suggestions.",
        "com.apple.proactiveeventtrackerd": "Tracks events used by proactive suggestions.",
        "com.apple.siri.acousticsignature": "Processes acoustic signatures for voice features.",
        "com.apple.siri.context.service": "Builds device context for Siri requests.",
        "com.apple.siriactionsd": "Executes Siri actions and App Intents.",
        "com.apple.siriinferenced": "Runs Siri inference and intent predictions.",
        "com.apple.siriknowledged": "Maintains knowledge and context used by Siri.",
        "com.apple.sirittsd": "Generates Siri's spoken responses.",
        "com.apple.speechmodeltrainingd": "Adapts on-device speech recognition models.",
        "com.apple.suggestd": "Generates system suggestions and predictions.",
        "com.apple.textunderstandingd": "Extracts meaning and entities from text.",
        "com.apple.voicebankingd": "Supports Personal Voice and voice banking.",
        "com.apple.voiced": "Manages system voices and speech assets.",
      ], alwaysEnabled: []),
    .init(
      id: "search", name: "Spotlight & Search",
      description: "On-device Spotlight and in-Settings search services.",
      downside: "Spotlight and Settings search return no results.", approxMemoryMB: 50,
      labels: [
        "com.apple.searchd", "com.apple.searchtoold", "com.apple.spotlightknowledged",
        "com.apple.spotlightknowledged.updater", "com.apple.corespotlightservice",
      ],
      serviceDescriptions: [
        "com.apple.corespotlightservice": "Indexes and searches app-provided content.",
        "com.apple.searchd": "Coordinates system search queries.",
        "com.apple.searchtoold": "Runs helper tasks for system search.",
        "com.apple.spotlightknowledged": "Builds knowledge used by Spotlight results.",
        "com.apple.spotlightknowledged.updater": "Refreshes Spotlight's knowledge data.",
      ], alwaysEnabled: []),
    .init(
      id: "icloud", name: "iCloud & Apple Account",
      description: "iCloud sync, Apple Account, keychain, and backup services.",
      downside: "iCloud sync, Apple Account, Keychain, and backup workflows will not work.",
      approxMemoryMB: 100,
      labels: [
        "com.apple.appleaccountd", "com.apple.appleaccounttransparencyd", "com.apple.appleidsetupd",
        "com.apple.akd", "com.apple.amsaccountsd", "com.apple.amsengagementd",
        "com.apple.amsondevicestoraged", "com.apple.cloudd", "com.apple.cloudphotod",
        "com.apple.ckdiscretionaryd", "com.apple.cloudsettingssyncagent", "com.apple.bird",
        "com.apple.syncdefaultsd", "com.apple.cdpd", "com.apple.sosd",
        "com.apple.SecureBackupDaemon", "com.apple.TrustedPeersHelper",
        "com.apple.protectedcloudstorage.protectedcloudkeysyncing", "com.apple.icloudmailagent",
        "com.apple.icloudsubscriptionoptimizerd", "com.apple.communicationtrustd",
      ],
      serviceDescriptions: [
        "com.apple.SecureBackupDaemon": "Handles secure backup and account recovery data.",
        "com.apple.TrustedPeersHelper": "Maintains trusted peers for iCloud Keychain.",
        "com.apple.akd": "Provides Apple Account authentication tokens.",
        "com.apple.amsaccountsd": "Manages App Store and media account state.",
        "com.apple.amsengagementd": "Handles App Store and media engagement messages.",
        "com.apple.amsondevicestoraged": "Stores Apple media-service data on the device.",
        "com.apple.appleaccountd": "Maintains Apple Account state on the device.",
        "com.apple.appleaccounttransparencyd": "Checks Apple Account security records.",
        "com.apple.appleidsetupd": "Handles Apple Account setup workflows.",
        "com.apple.bird": "Synchronizes iCloud Drive files.",
        "com.apple.cdpd": "Handles iCloud data-protection setup and recovery.",
        "com.apple.ckdiscretionaryd": "Schedules non-urgent CloudKit transfers.",
        "com.apple.cloudd": "Synchronizes CloudKit databases and records.",
        "com.apple.cloudphotod": "Synchronizes the iCloud Photos library.",
        "com.apple.cloudsettingssyncagent":
          "Synchronizes supported system settings through iCloud.",
        "com.apple.communicationtrustd": "Maintains communication trust and safety state.",
        "com.apple.icloudmailagent": "Runs background services for iCloud Mail.",
        "com.apple.icloudsubscriptionoptimizerd":
          "Evaluates iCloud storage subscription recommendations.",
        "com.apple.protectedcloudstorage.protectedcloudkeysyncing":
          "Synchronizes protected cloud encryption keys.",
        "com.apple.sosd": "Synchronizes iCloud Keychain secure items.",
        "com.apple.syncdefaultsd": "Synchronizes supported preferences between devices.",
      ], alwaysEnabled: []),
    .init(
      id: "store", name: "App Store, Push & Media",
      description: "App Store, push notification, StoreKit, and media services.",
      downside: "Remote push notifications and StoreKit or App Store testing will not work.",
      approxMemoryMB: 80,
      labels: [
        "com.apple.appstored", "com.apple.appstorecomponentsd", "com.apple.apsd",
        "com.apple.itunescloudd", "com.apple.itunesstored", "com.apple.storekitd",
        "com.apple.amsaccountsd", "com.apple.amsengagementd", "com.apple.amsondevicestoraged",
        "com.apple.passd", "com.apple.financed", "com.apple.videosubscriptionsd",
        "com.apple.assetsubscriptiond", "com.apple.musicd",
      ],
      serviceDescriptions: [
        "com.apple.amsaccountsd": "Manages App Store and media account state.",
        "com.apple.amsengagementd": "Handles App Store and media engagement messages.",
        "com.apple.amsondevicestoraged": "Stores Apple media-service data on the device.",
        "com.apple.appstorecomponentsd": "Provides background components used by the App Store.",
        "com.apple.appstored": "Installs and updates apps from the App Store.",
        "com.apple.apsd": "Receives Apple Push Notification service messages.",
        "com.apple.assetsubscriptiond": "Manages subscribed media assets and downloads.",
        "com.apple.financed": "Provides Wallet transaction and finance services.",
        "com.apple.itunescloudd": "Synchronizes purchased and cloud media libraries.",
        "com.apple.itunesstored": "Handles media-store accounts and purchases.",
        "com.apple.musicd": "Runs background Music library and playback services.",
        "com.apple.passd": "Manages Wallet passes and Apple Pay state.",
        "com.apple.storekitd": "Processes StoreKit products and transactions.",
        "com.apple.videosubscriptionsd": "Manages video subscriptions and TV providers.",
      ], alwaysEnabled: []),
    .init(
      id: "pim", name: "Mail, Calendar & Contacts",
      description: "Mail, Calendar, Contacts, Reminders, and related sync services.",
      downside: "Contacts, Calendar, Reminders, and Mail-backed pickers or sync may fail.",
      approxMemoryMB: 80,
      labels: [
        "com.apple.email.maild", "com.apple.exchangesyncd", "com.apple.dataaccess.dataaccessd",
        "com.apple.calaccessd", "com.apple.remindd", "com.apple.contactsd",
        "com.apple.contacts.postersyncd", "com.apple.peopled",
      ],
      serviceDescriptions: [
        "com.apple.calaccessd": "Provides access to Calendar event data.",
        "com.apple.contacts.postersyncd": "Synchronizes Contact Posters.",
        "com.apple.contactsd": "Provides access to the Contacts database.",
        "com.apple.dataaccess.dataaccessd": "Synchronizes CalDAV, CardDAV, and related accounts.",
        "com.apple.email.maild": "Fetches, indexes, and sends Mail account data.",
        "com.apple.exchangesyncd": "Synchronizes Microsoft Exchange account data.",
        "com.apple.peopled": "Builds people and relationship suggestions.",
        "com.apple.remindd": "Stores and synchronizes reminders.",
      ], alwaysEnabled: []),
    .init(
      id: "web", name: "Safari Sync & Web Services",
      description: "Safari sync, web push, privacy, and universal-link services.",
      downside: "Universal links and Safari sync or background web services will not work.",
      approxMemoryMB: 50,
      labels: [
        "com.apple.SafariBookmarksSyncAgent", "com.apple.Safari.History",
        "com.apple.Safari.passwordbreachd", "com.apple.Safari.SafeBrowsing.Service",
        "com.apple.safarifetcherd", "com.apple.WebBookmarks.webbookmarksd",
        "com.apple.webkit.adattributiond", "com.apple.webkit.webpushd", "com.apple.webprivacyd",
        "com.apple.swcd",
      ],
      serviceDescriptions: [
        "com.apple.Safari.History": "Maintains and synchronizes Safari history.",
        "com.apple.Safari.SafeBrowsing.Service": "Checks sites against unsafe browsing data.",
        "com.apple.Safari.passwordbreachd": "Checks saved passwords for known data leaks.",
        "com.apple.SafariBookmarksSyncAgent": "Synchronizes Safari bookmarks through iCloud.",
        "com.apple.WebBookmarks.webbookmarksd":
          "Maintains web bookmarks, clips, and Reading List data.",
        "com.apple.safarifetcherd": "Fetches Safari content in the background.",
        "com.apple.swcd": "Matches universal links with installed apps.",
        "com.apple.webkit.adattributiond": "Processes privacy-preserving web ad attribution.",
        "com.apple.webkit.webpushd": "Receives push notifications for websites.",
        "com.apple.webprivacyd": "Maintains Safari privacy-protection data.",
      ], alwaysEnabled: []),
    .init(
      id: "family", name: "Family & Screen Time",
      description: "Family Sharing, Screen Time, and usage tracking.",
      downside: "Family Sharing, Screen Time, and usage tracking stop working.", approxMemoryMB: 65,
      labels: [
        "com.apple.familycircled", "com.apple.FamilyControlsAgent", "com.apple.familynotification",
        "com.apple.askpermissiond", "com.apple.asktod", "com.apple.ScreenTimeAgent",
        "com.apple.ScreenTimeSettingsAgent", "com.apple.UsageTrackingAgent",
      ],
      serviceDescriptions: [
        "com.apple.FamilyControlsAgent": "Applies parental and Family Controls restrictions.",
        "com.apple.ScreenTimeAgent": "Enforces Screen Time limits and reports usage.",
        "com.apple.ScreenTimeSettingsAgent": "Connects Screen Time data to Settings.",
        "com.apple.UsageTrackingAgent": "Tracks app and website usage duration.",
        "com.apple.askpermissiond": "Handles Ask to Buy permission requests.",
        "com.apple.asktod": "Routes family approval prompts and responses.",
        "com.apple.familycircled": "Maintains Family Sharing membership and state.",
        "com.apple.familynotification": "Delivers Family Sharing invitations and notices.",
      ], alwaysEnabled: []),
    .init(
      id: "health", name: "Health, Home & Fitness",
      description: "HealthKit, HomeKit, and Fitness services.",
      downside: "HealthKit, HomeKit, and Fitness integrations will not work.", approxMemoryMB: 135,
      labels: [
        "com.apple.healthd", "com.apple.healthappd", "com.apple.healthcontentd",
        "com.apple.healtheventsd", "com.apple.healthrecordsd", "com.apple.finhealthd",
        "com.apple.homed", "com.apple.homeeventsd", "com.apple.fitcore",
        "com.apple.fitcore.session", "com.apple.fitnesscoachingd", "com.apple.fitnessintelligenced",
        "com.apple.activityawardsd", "com.apple.activitysharingd",
      ],
      serviceDescriptions: [
        "com.apple.activityawardsd": "Tracks Activity awards and achievements.",
        "com.apple.activitysharingd": "Synchronizes shared Activity and Fitness data.",
        "com.apple.finhealthd": "Analyzes Wallet transactions and financial-health data.",
        "com.apple.fitcore": "Runs Apple Fitness content and background services.",
        "com.apple.fitcore.session": "Manages active Apple Fitness sessions.",
        "com.apple.fitnesscoachingd": "Provides Fitness coaching recommendations.",
        "com.apple.fitnessintelligenced": "Generates personalized Fitness insights.",
        "com.apple.healthappd": "Runs background tasks for the Health app.",
        "com.apple.healthcontentd": "Provides educational and recommended health content.",
        "com.apple.healthd": "Stores and serves HealthKit data.",
        "com.apple.healtheventsd": "Processes health events and related notifications.",
        "com.apple.healthrecordsd": "Synchronizes clinical health records.",
        "com.apple.homed": "Manages HomeKit accessories, rooms, and automations.",
        "com.apple.homeeventsd": "Processes HomeKit events and automation triggers.",
      ], alwaysEnabled: []),
    .init(
      id: "photos", name: "Photos & Media Analysis",
      description: "Photos library, photo analysis, and media analysis services.",
      downside: "Photo picker, Photos-library workflows, and media analysis may fail.",
      approxMemoryMB: 60,
      labels: [
        "com.apple.photoanalysisd", "com.apple.photosface", "com.apple.mediaanalysisd",
        "com.apple.mediaanalysisd.service", "com.apple.mediastream.mstreamd",
        "com.apple.medialibraryd", "com.apple.assetsd", "com.apple.assetsd.nebulad",
      ],
      serviceDescriptions: [
        "com.apple.assetsd": "Provides access to Photos library assets.",
        "com.apple.assetsd.nebulad": "Handles cloud-backed Photos asset transfers.",
        "com.apple.mediaanalysisd": "Analyzes image, video, and audio content.",
        "com.apple.mediaanalysisd.service": "Runs isolated media-analysis work.",
        "com.apple.medialibraryd": "Maintains the system media library database.",
        "com.apple.mediastream.mstreamd": "Synchronizes shared and streamed photo content.",
        "com.apple.photoanalysisd": "Analyzes photos for scenes, people, and search.",
        "com.apple.photosface": "Performs face detection for the Photos library.",
      ], alwaysEnabled: []),
    .init(
      id: "apps", name: "News, Weather, Maps & Games",
      description: "News, Weather, Maps, Tips, and game services.",
      downside:
        "News, Weather, Maps background data, and game-controller services are unavailable.",
      approxMemoryMB: 90,
      labels: [
        "com.apple.newsd", "com.apple.weatherd", "com.apple.Maps.mapssyncd",
        "com.apple.Maps.mapspushd", "com.apple.Maps.geocorrectiond", "com.apple.maps.destinationd",
        "com.apple.MapKit.SnapshotService", "com.apple.jetpackassetd", "com.apple.tipsd",
        "com.apple.gamed", "com.apple.gamesaved", "com.apple.GameController.gamecontrollerd",
      ],
      serviceDescriptions: [
        "com.apple.GameController.gamecontrollerd": "Discovers controllers and routes their input.",
        "com.apple.MapKit.SnapshotService": "Renders static map snapshots for apps.",
        "com.apple.Maps.geocorrectiond": "Improves and corrects map location data.",
        "com.apple.Maps.mapspushd": "Receives background updates for Maps.",
        "com.apple.Maps.mapssyncd": "Synchronizes Maps favorites, guides, and history.",
        "com.apple.gamed": "Provides Game Center accounts and multiplayer state.",
        "com.apple.gamesaved": "Synchronizes supported game save data.",
        "com.apple.jetpackassetd": "Downloads assets used by Apple content apps.",
        "com.apple.maps.destinationd": "Predicts and maintains suggested destinations.",
        "com.apple.newsd": "Downloads and refreshes Apple News content.",
        "com.apple.tipsd": "Selects and refreshes content for the Tips app.",
        "com.apple.weatherd": "Fetches forecasts and weather data.",
      ], alwaysEnabled: []),
    .init(
      id: "messaging", name: "Messaging & FaceTime",
      description: "iMessage, FaceTime, call, and identity services.",
      downside: "iMessage, FaceTime, and related identity services will not work.",
      approxMemoryMB: 60,
      labels: [
        "com.apple.identityservicesd", "com.apple.ids_simd",
        "com.apple.imautomatichistorydeletionagent", "com.apple.imcore.imtransferagent",
        "com.apple.imdpersistence.IMDPersistenceAgent", "com.apple.facetimemessagestored",
        "com.apple.telephonyutilities.callservicesd",
      ],
      serviceDescriptions: [
        "com.apple.facetimemessagestored": "Stores FaceTime messages and related data.",
        "com.apple.identityservicesd": "Maintains identities used by iMessage and FaceTime.",
        "com.apple.ids_simd": "Provides simulator support for Apple identity services.",
        "com.apple.imautomatichistorydeletionagent":
          "Removes Messages history according to retention settings.",
        "com.apple.imcore.imtransferagent": "Transfers Messages attachments and media.",
        "com.apple.imdpersistence.IMDPersistenceAgent":
          "Stores Messages conversations and metadata.",
        "com.apple.telephonyutilities.callservicesd": "Coordinates FaceTime and system call state.",
      ], alwaysEnabled: []),
    .init(
      id: "connectivity", name: "Sharing & Device Connectivity",
      description: "AirDrop, Continuity, CarPlay, Watch, and Find My services.",
      downside: "AirDrop, Continuity, CarPlay, Watch, and Find My connectivity will not work.",
      approxMemoryMB: 65,
      labels: [
        "com.apple.rapportd", "com.apple.companiond", "com.apple.carkitd", "com.apple.wcd",
        "com.apple.tvremoted", "com.apple.avatarsd", "com.apple.stickersd",
        "com.apple.sociallayerd", "com.apple.announced", "com.apple.navd",
        "com.apple.findmy.findmylocated",
      ],
      serviceDescriptions: [
        "com.apple.announced": "Supports announced notifications and audio messages.",
        "com.apple.avatarsd": "Maintains avatars and Memoji assets.",
        "com.apple.carkitd": "Provides CarPlay connection and vehicle services.",
        "com.apple.companiond": "Coordinates communication with paired companion devices.",
        "com.apple.findmy.findmylocated": "Provides device location data to Find My.",
        "com.apple.navd": "Coordinates background navigation state.",
        "com.apple.rapportd": "Discovers nearby devices for Continuity features.",
        "com.apple.sociallayerd": "Supports social sharing and activity features.",
        "com.apple.stickersd": "Maintains sticker packs and recently used stickers.",
        "com.apple.tvremoted": "Provides Apple TV discovery and remote control.",
        "com.apple.wcd": "Handles connectivity with a paired Apple Watch.",
      ],
      alwaysEnabled: [
        .init(label: "com.apple.sharingd", reason: "Required for system share sheets.")
      ]),
    .init(
      id: "telemetry", name: "Ads, Diagnostics & Telemetry",
      description: "DeviceCheck, ad privacy, analytics, diagnostics, and feedback services.",
      downside: "DeviceCheck plus analytics, diagnostics, and feedback services are unavailable.",
      approxMemoryMB: 105,
      labels: [
        "com.apple.ap.adprivacyd", "com.apple.ap.promotedcontentd",
        "com.apple.diagnosticextensionsd", "com.apple.feedbackd", "com.apple.rtcreportingd",
        "com.apple.securityuploadd", "com.apple.geoanalyticsd", "com.apple.triald",
        "com.apple.followupd", "com.apple.purplebuddy.budd", "com.apple.devicecheckd",
      ],
      serviceDescriptions: [
        "com.apple.ap.adprivacyd": "Maintains advertising privacy preferences and state.",
        "com.apple.ap.promotedcontentd": "Fetches and manages promoted Apple content.",
        "com.apple.devicecheckd": "Provides DeviceCheck and app-attestation services.",
        "com.apple.diagnosticextensionsd": "Runs system diagnostic data collectors.",
        "com.apple.feedbackd": "Collects and submits system feedback reports.",
        "com.apple.followupd": "Schedules account and setup follow-up notices.",
        "com.apple.geoanalyticsd": "Collects Maps and location-quality analytics.",
        "com.apple.purplebuddy.budd": "Maintains Setup Assistant completion state.",
        "com.apple.rtcreportingd": "Reports diagnostics for real-time communications.",
        "com.apple.securityuploadd": "Uploads security and trust telemetry.",
        "com.apple.triald": "Manages system feature experiments and configurations.",
      ], alwaysEnabled: []),
    .init(
      id: "other", name: "Other Background Services",
      description: "Wallet, business services, assets, and miscellaneous background daemons.",
      downside:
        "Wallet, merchant, business, asset, and miscellaneous background services are unavailable.",
      approxMemoryMB: 195,
      labels: [
        "com.apple.financed", "com.apple.passd", "com.apple.merchantd", "com.apple.coreidvd",
        "com.apple.businessservicesd", "com.apple.deviceaccessd", "com.apple.replicatord",
        "com.apple.linkd", "com.apple.ind", "com.apple.storagedatad", "com.apple.StatusKitAgent",
        "com.apple.countryd", "com.apple.mobileassetd",
        "com.apple.managedconfiguration.passcodenagd",
      ],
      serviceDescriptions: [
        "com.apple.StatusKitAgent": "Shares Focus, presence, and status between devices.",
        "com.apple.businessservicesd": "Supports Apple business messaging and services.",
        "com.apple.coreidvd": "Manages supported digital identity credentials.",
        "com.apple.countryd": "Determines regional availability for system features.",
        "com.apple.deviceaccessd": "Coordinates app access to supported accessories.",
        "com.apple.financed": "Provides Wallet transaction and finance services.",
        "com.apple.ind": "Receives background iCloud notifications.",
        "com.apple.linkd": "Indexes App Intents and shortcut suggestions.",
        "com.apple.managedconfiguration.passcodenagd": "Enforces managed passcode requirements.",
        "com.apple.merchantd": "Looks up merchant details for Wallet transactions.",
        "com.apple.mobileassetd": "Downloads and manages system asset packages.",
        "com.apple.passd": "Manages Wallet passes and Apple Pay state.",
        "com.apple.replicatord": "Replicates supported system data between services.",
        "com.apple.storagedatad": "Calculates storage usage shown by the system.",
      ], alwaysEnabled: []),
  ]
  static let slimmable = Set(categories.flatMap(\.labels))
  static let compatibility = Set(categories.flatMap { $0.alwaysEnabledServices.map(\.label) })
  static let managed = slimmable.union(compatibility)
  static func desired(except: Set<String>, keep: Set<String>) throws -> Set<String> {
    guard except.isSubset(of: Set(categories.map(\.id))), keep.isSubset(of: slimmable) else {
      throw SimulatorError("Unknown service or category in the selected profile.")
    }
    let retained = categories.filter { except.contains($0.id) }.flatMap(\.labels)
    return slimmable.subtracting(retained).subtracting(keep).subtracting(compatibility)
  }
  static func delta(current: Set<String>, desired: Set<String>) -> (
    disable: [String], enable: [String]
  ) {
    let desired = desired.intersection(slimmable).subtracting(compatibility)
    return (
      desired.subtracting(current).sorted(),
      current.intersection(managed).subtracting(desired).sorted()
    )
  }
  static func supportsPersistence(_ version: String) -> Bool {
    let parts = version.split(separator: ".")
    guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
      return false
    }
    return major > 18 || (major == 18 && minor >= 5)
  }
  static func parseDisabled(_ output: String) -> Set<String> {
    var labels = Set<String>()
    for line in output.split(separator: "\n") {
      let pieces = line.components(separatedBy: "\"")
      guard pieces.count >= 3, let arrow = pieces[2].range(of: "=>") else { continue }
      let value = pieces[2][arrow.upperBound...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("disabled") || value.hasPrefix("true") { labels.insert(pieces[1]) }
    }
    return labels
  }
}
