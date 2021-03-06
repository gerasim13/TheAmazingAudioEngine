Pod::Spec.new do |s|
  s.name         = "TheAmazingAudioEngine"
  s.version      = "1.5.9"
  s.summary      = "Core Audio, Cordially: A sophisticated framework for iOS audio applications, built so you don't have to."
  s.homepage     = "http://theamazingaudioengine.com"
  s.license      = 'zlib'
  s.author       = { "Michael Tyson" => "michael@atastypixel.com" }
  s.source       = { :git => "https://github.com/gerasim13/TheAmazingAudioEngine.git", :tag => "1.5.9" }
  s.deprecated   = true
  s.requires_arc = true
  s.ios.deployment_target = '7.0'
  s.osx.deployment_target = '10.9'
  s.tvos.deployment_target = '9.0'
  s.frameworks        = 'AudioToolbox', 'Accelerate'
  s.source_files      = 'TheAmazingAudioEngine/**/*.{h,m,c}', 
  						          'Modules/**/*.{h,m,c}'
  s.exclude_files     = 'Modules/TPCircularBuffer', 
  						          'TheAmazingAudioEngine/AERealtimeWatchdog*', 
  						          'TheAmazingAudioEngine/Library/TPCircularBuffer'
  s.osx.exclude_files = 'Modules/Filters/AEReverbFilter.*'
  s.dependency 'TPCircularBuffer'
end
