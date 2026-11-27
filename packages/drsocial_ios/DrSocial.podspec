# CocoaPods spec for apps that use CocoaPods (React Native among them). Swift Package Manager uses Package.swift.
Pod::Spec.new do |s|
  s.name         = 'DrSocial'
  s.version      = '0.1.0'
  s.summary      = 'The DrSocial mobile SDK for iOS (API v1).'
  s.homepage     = 'https://social.drscroll.com'
  s.license      = { :type => 'Proprietary' }
  s.author       = 'DR. Scroll'
  s.source       = { :git => 'https://github.com/drscroll-Rino/drsocial-SDK.git', :tag => "ios-#{s.version}" }
  s.platform     = :ios, '14.0'
  s.swift_version = '5.9'
  s.source_files = 'Sources/DrSocial/**/*.swift'
  s.resource_bundles = { 'DrSocialPrivacy' => ['Sources/DrSocial/PrivacyInfo.xcprivacy'] }
  s.frameworks   = 'CryptoKit', 'DeviceCheck', 'UserNotifications', 'StoreKit', 'CoreHaptics'
  s.weak_frameworks = 'ActivityKit'
end
