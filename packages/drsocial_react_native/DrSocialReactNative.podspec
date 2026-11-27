require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# The React Native bridge. The SDK itself is the DrSocial pod (packages/drsocial_ios/DrSocial.podspec): the app's
# Podfile names it by path (see README).
Pod::Spec.new do |s|
  s.name         = 'DrSocialReactNative'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = 'https://social.drscroll.com'
  s.license      = { :type => 'Proprietary' }
  s.author       = 'DR. Scroll'
  s.source       = { :git => 'https://github.com/drscroll-Rino/drsocial-SDK.git', :tag => "rn-#{s.version}" }
  s.platform     = :ios, '14.0'
  s.swift_version = '5.9'
  s.source_files = 'ios/**/*.{swift,m}'
  s.dependency 'DrSocial'
  s.dependency 'React-Core'
end
