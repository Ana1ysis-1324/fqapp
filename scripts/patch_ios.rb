#!/usr/bin/env ruby
# Patches the Flutter iOS Runner so it statically links the Rust core:
#  - copies the login plugin (FanqieAccountPlugin.swift) into ios/Runner/
#  - injects the FRB C header into the bridging header
#  - injects the plugin registration into the GENERATED AppDelegate
#    (works for both old and new Flutter iOS templates, incl. SceneDelegate)
#  - adds libfqapi_core.a to the Runner target's link phase + search paths
# Runs on the GitHub macOS runner (ruby + xcodeproj gem available).
require 'fileutils'
require 'xcodeproj'

ROOT = Dir.pwd
NATIVE = File.join(ROOT, 'ios_native')
RUNNER = File.join(ROOT, 'ios', 'Runner')

abort "缺少 ios/Runner 目录，请先运行 flutter create --platforms=ios ." unless Dir.exist?(RUNNER)

# 1) Copy native sources (login plugin only; AppDelegate is patched in place).
FileUtils.cp(File.join(NATIVE, 'FanqieAccountPlugin.swift'), RUNNER) if File.exist?(File.join(NATIVE, 'FanqieAccountPlugin.swift'))
puts 'copied FanqieAccountPlugin.swift -> ios/Runner/'

# 2) Bridging header includes the FRB C header (makes Rust C API visible to Swift).
header = File.join(RUNNER, 'Runner-Bridging-Header.h')
if File.exist?(header)
  txt = File.read(header)
  unless txt.include?('frb_generated.h')
    File.open(header, 'a') { |f| f.puts '#include "frb_generated.h"' }
    puts 'appended #include "frb_generated.h" to bridging header'
  end
else
  File.write(header, "#import \"Flutter/Flutter.h\"\n#include \"frb_generated.h\"\n")
  puts 'created Runner-Bridging-Header.h'
end

# 2b) Info.plist: relax ATS (the app talks to plain-http fanqie APIs like the
#     Android build) and allow background audio (听书 / TTS playback).
#     IMPORTANT: insert the new <key>/<dict> pair INSIDE the root <dict>, i.e.
#     right before the closing </dict></plist> — NOT between </dict> and </plist>.
info = File.join(RUNNER, 'Info.plist')
if File.exist?(info)
  plist = File.read(info)
  root_re = /<\/dict>\s*<\/plist>/m   # the root dict close + plist close (unique)

  unless plist.include?('NSAppTransportSecurity')
    ats = "<key>NSAppTransportSecurity</key>\n" \
          "<dict>\n" \
          "<key>NSAllowsArbitraryLoads</key>\n<true/>\n" \
          "<key>NSAllowsLocalNetworking</key>\n<true/>\n" \
          "</dict>\n"
    plist.sub!(root_re) { |m| ats + m }
    File.write(info, plist)
    puts 'injected NSAppTransportSecurity into Info.plist'
  end

  unless plist.include?('UIBackgroundModes')
    bg = "<key>UIBackgroundModes</key>\n<array>\n<string>audio</string>\n</array>\n"
    plist.sub!(root_re) { |m| bg + m }
    File.write(info, plist)
    puts 'injected UIBackgroundModes(audio) into Info.plist'
  end
end

# 3) Inject the plugin registration into the GENERATED AppDelegate.
#    Using the standard FlutterPlugin registrar works in both non-scene and
#    SceneDelegate-based templates (same mechanism GeneratedPluginRegistrant uses).
app_del = File.join(RUNNER, 'AppDelegate.swift')
if File.exist?(app_del)
  ad = File.read(app_del)
  inject = <<~SWIFT
    // fqapp: register the Fanqie account login plugin (channel fqapp/fanqie_account)
    if let registrar = self.registrar(forPlugin: "FanqieAccountPlugin") {
      FanqieAccountPlugin.register(with: registrar)
    }
  SWIFT
  unless ad.include?('FanqieAccountPlugin.register')
    if ad.include?('GeneratedPluginRegistrant.register(with: self)')
      ad.sub!('GeneratedPluginRegistrant.register(with: self)') { |m| m + "\n" + inject }
    else
      # fallback: insert right before the first `return super.application(...)`
      ad.sub!(/(\n\s*return super\.application\([^;]*;)/) { |m| "\n" + inject + m }
    end
    File.write(app_del, ad)
    puts 'injected FanqieAccountPlugin registration into AppDelegate.swift'
  end
end

# 4) Open the Xcode project (handle both old and new template layouts).
candidates = [
  File.join(ROOT, 'ios', 'Runner.xcodeproj'),   # Flutter >= ~3.40
  File.join(RUNNER, 'Runner.xcodeproj'),        # older layout
]
PROJ_PATH = candidates.find { |p| File.exist?(p) }
abort "找不到 Runner.xcodeproj（尝试过 #{candidates.join(', ')}）" unless PROJ_PATH
puts "using xcodeproj: #{PROJ_PATH}"

proj = Xcodeproj::Project.open(PROJ_PATH)
runner_target = proj.targets.find { |t| t.name == 'Runner' }
abort '未找到 Runner target' unless runner_target

# 5) Embed the Rust dynamic framework. The FRB Dart loader on iOS dlopens
#    'fqapi_core.framework/fqapi_core' FIRST (see the runtime error captured
#    on device) — a bare static lib linked into Runner is never seen by it.
#    So ship the cdylib as fqapi_core.framework inside Runner.app/Frameworks.
fw_path = File.join(RUNNER, 'fqapi_core.framework')
abort "缺少 #{fw_path}，请先运行 scripts/build_rust_backend_ios.sh 打包动态框架。" unless File.directory?(fw_path)

runner_group = proj.main_group.children.find { |g| g.respond_to?(:path) && g.path == 'Runner' }
runner_group ||= proj.main_group

fw_ref = runner_group.files.find { |f| f.respond_to?(:path) && f.path == 'fqapi_core.framework' } ||
         runner_group.new_file('fqapi_core.framework')

embed = runner_target.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' } ||
        runner_target.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10'   # 10 = Frameworks dir inside the .app
unless embed.files_references.include?(fw_ref)
  embed.add_file_reference(fw_ref)
end
embed.files.each do |f|
  next unless f.file_ref == fw_ref
  attrs = (f.settings && f.settings['ATTRIBUTES']) || []
  f.settings = { 'ATTRIBUTES' => (attrs | ['CodeSignOnCopy']) }
end
puts 'embedded fqapi_core.framework (Embed Frameworks + CodeSignOnCopy)'

# 6) Build settings: header search path + explicit bridging header so
#    `#include "frb_generated.h"` is processed by Swift.
runner_target.build_configurations.each do |config|
  s = config.build_settings
  s['HEADER_SEARCH_PATHS']  = Array(s['HEADER_SEARCH_PATHS']) + ['$(SRCROOT)/Runner']
  s['HEADER_SEARCH_PATHS'].uniq!
  s['SWIFT_OBJC_BRIDGING_HEADER'] = 'Runner/Runner-Bridging-Header.h'
end

proj.save
puts 'patched Runner.xcodeproj: linked libfqapi_core.a + header/library search paths'
