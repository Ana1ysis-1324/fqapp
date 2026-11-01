#!/usr/bin/env ruby
# Patches the Flutter iOS Runner so it statically links the Rust core:
#  - copies the native source files from ios_native/ into ios/Runner/
#  - injects the FRB C header into the bridging header
#  - adds the static lib + header search paths to the Xcode build settings
# Runs on the GitHub macOS runner (ruby + xcodeproj gem available).
require 'fileutils'
require 'xcodeproj'

ROOT = Dir.pwd
NATIVE = File.join(ROOT, 'ios_native')
RUNNER = File.join(ROOT, 'ios', 'Runner')
PROJ_PATH = File.join(RUNNER, 'Runner.xcodeproj')

abort "缺少 ios/Runner 目录，请先运行 flutter create --platforms=ios ." unless Dir.exist?(RUNNER)

# 1) Copy native sources (login plugin, app delegate, modulemap).
FileUtils.cp(File.join(NATIVE, 'FanqieAccountPlugin.swift'), RUNNER) if File.exist?(File.join(NATIVE, 'FanqieAccountPlugin.swift'))
FileUtils.cp(File.join(NATIVE, 'AppDelegate.swift'),        RUNNER) if File.exist?(File.join(NATIVE, 'AppDelegate.swift'))
FileUtils.cp(File.join(NATIVE, 'fqapi_core.modulemap'),     RUNNER) if File.exist?(File.join(NATIVE, 'fqapi_core.modulemap'))
puts 'copied ios_native/* -> ios/Runner/'

# 2) Ensure the bridging header includes the FRB C header.
header = File.join(RUNNER, 'Runner-Bridging-Header.h')
if File.exist?(header)
  txt = File.read(header)
  unless txt.include?('frb_generated.h')
    File.open(header, 'a') { |f| f.puts '#include "frb_generated.h"' }
    puts 'appended #include "frb_generated.h" to bridging header'
  end
else
  # Flutter 较新版本用 AppDelegate 直接调用，仍可放一个 bridging header。
  File.write(header, "#import \"Flutter/Flutter.h\"\n#include \"frb_generated.h\"\n")
  puts 'created Runner-Bridging-Header.h'
end

# 3) Patch Xcode build settings (Runner target only).
proj = Xcodeproj::Project.open(PROJ_PATH)
runner_target = proj.targets.find { |t| t.name == 'Runner' }
abort '未找到 Runner target' unless runner_target

runner_target.build_configurations.each do |config|
  s = config.build_settings
  s['HEADER_SEARCH_PATHS']  = Array(s['HEADER_SEARCH_PATHS']) + ['$(SRCROOT)/Runner']
  s['HEADER_SEARCH_PATHS'].uniq!
  s['LIBRARY_SEARCH_PATHS'] = Array(s['LIBRARY_SEARCH_PATHS']) + ['$(SRCROOT)/Runner']
  s['LIBRARY_SEARCH_PATHS'].uniq!
  s['SWIFT_INCLUDE_PATHS']  = Array(s['SWIFT_INCLUDE_PATHS']) + ['$(SRCROOT)/Runner']
  s['SWIFT_INCLUDE_PATHS'].uniq!
  flags = s['OTHER_LDFLAGS']
  flags = flags.is_a?(Array) ? flags.dup : [flags.to_s].reject(&:empty?)
  flags << '-lfqapi_core' unless flags.include?('-lfqapi_core')
  s['OTHER_LDFLAGS'] = flags
end
proj.save
puts 'patched Runner.xcodeproj: HEADER/LIBRARY/SWIFT search paths + -lfqapi_core'
