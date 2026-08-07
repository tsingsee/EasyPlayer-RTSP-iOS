platform :ios, '12.0'

target 'EasyPlayerRTSP' do
    # Uncomment the next line if you're using Swift or would like to use dynamic frameworks
    use_frameworks!

    # Pods for EasyRlayer

    pod 'Masonry'
    pod 'Bugly'

    pod 'RTRootNavigationController'
    pod 'IQKeyboardManager'
    pod 'YYKit'

    pod 'WHToast'

    #    pod 'ReactiveCocoa', '~> 2.5'
    pod 'ReactiveCocoa', :git => 'https://github.com/zhao0/ReactiveCocoa.git', :tag => '2.5.2'

end

post_install do |installer|
    installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
        end
    end

    # iOS 18: fix YYKVStorage sqlite close crash by finalizing cached statements.
    yykit_file = 'Pods/YYKit/YYKit/Cache/YYKVStorage.m'
    if File.exist?(yykit_file)
        content = File.read(yykit_file)
        new_snippet = <<~'NEW'
            if (_dbStmtCache) {
                CFIndex size = CFDictionaryGetCount(_dbStmtCache);
                if (size > 0) {
                    const void **values = (const void **)malloc(sizeof(void *) * size);
                    if (values) {
                        CFDictionaryGetKeysAndValues(_dbStmtCache, NULL, values);
                        for (CFIndex i = 0; i < size; i++) {
                            sqlite3_stmt *stmt = (sqlite3_stmt *)values[i];
                            if (stmt) sqlite3_finalize(stmt);
                        }
                        free(values);
                    }
                }
                CFRelease(_dbStmtCache);
            }
            _dbStmtCache = NULL;
        NEW

        unless content.include?('CFDictionaryGetCount(_dbStmtCache)')
            replaced = content.sub(/if \(_dbStmtCache\) CFRelease\(_dbStmtCache\);\s*_dbStmtCache = NULL;/m, new_snippet)
            if replaced != content
                File.write(yykit_file, replaced)
                puts 'Applied YYKit sqlite finalize fix.'
            else
                puts 'Skip YYKit fix: target snippet not found.'
            end
        else
            puts 'YYKit sqlite finalize fix already present.'
        end
    else
        puts "Skip YYKit fix: #{yykit_file} not found."
    end
end
