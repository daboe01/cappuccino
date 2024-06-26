/*
 * Nib2Cib.j
 * nib2cib
 *
 * Created by Francisco Tolmasky and Aparajita Fishman.
 * Copyright 2008, 280 North, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
*/

@import <Foundation/CPObject.j>
@import <Foundation/CPArray.j>
@import <Foundation/CPDictionary.j>
@import <Foundation/CPString.j>
@import <AppKit/CPApplication.j>
@import <BlendKit/BlendKit.j>

@import "Nib2CibKeyedUnarchiver.j"
@import "Converter.j"
@import "Converter+Mac.j"

Nib2CibColorizeOutput = YES;

var PATH = require("path");
var fs = require("fs");
var child_process = require("child_process");

var /* FILE = require("file"), */
    /* OS = require("os"), */
    //SYS = require("system"),
    FileList = ObjectiveJ.utils.filelist.FileList,
    stream = ObjectiveJ.term.stream,
    StaticResource = ObjectiveJ.StaticResource,

    DefaultTheme = "Aristo2",
    BuildTypes = ["Debug", "Release"],
    DefaultFile = "MainMenu",
    AllowedStoredOptionsRe = new RegExp("^(defaultTheme|auxThemes|verbosity|quiet|frameworks|format)$"),
    ArgsRe = /"[^\"]+"|'[^\']+'|\S+/g,

    SharedNib2Cib = nil;



@implementation Nib2Cib : CPObject <CPBundleDelegate>
{
    CPArray         commandLineArgs;
    JSObject        parser;
    JSObject        commandLineOptions;
    JSObject        nibInfo;
    CPString        appDirectory @accessors(readonly);
    CPDictionary    frameworks @accessors(readonly);
    CPString        appResourceDirectory @accessors(readonly);
    CPDictionary    infoPlist @accessors(readonly);
    CPArray         userNSClasses @accessors(readonly);
    CPArray         themes @accessors(readonly);
}

+ (Nib2Cib)sharedNib2Cib
{
    return SharedNib2Cib;
}

+ (CPTheme)defaultTheme
{
    return [SharedNib2Cib themes][0];
}

- (id)initWithArgs:(CPArray)theArgs
{
    self = [super init];

    if (self)
    {
        if (!SharedNib2Cib)
            SharedNib2Cib = self;

        commandLineArgs = theArgs;
        parser = new (ObjectiveJ.parser.Parser)();
        nibInfo = {};
        appDirectory = @"";
        frameworks = [CPDictionary dictionary];
        appResourceDirectory = @"";
        infoPlist = @{};
        userNSClasses = [];
        themes = [];
    }

    return self;
}

- (void)run
{
    try
    {
        commandLineOptions = [self parseOptionsFromArgs:commandLineArgs];

        Nib2CibColorizeOutput = !commandLineOptions.noColors;
        [self setLogLevel:commandLineOptions.quiet ? -1 : commandLineOptions.verbosity];
        [self checkPrerequisites];

        if (commandLineOptions.watch)
            [self watchWithOptions:commandLineOptions];
        else
        {
            [self convertWithOptions:commandLineOptions inputPath:nil completionHandler:function(success) {
                if (!success) {
                    process.exit(1);
                }
            }];
        }
    }
    catch (anException)
    {
        [self logError:[self exceptionReason:anException]];
        process.exit(1);
    }
}

- (void)checkPrerequisites
{
/*     var fontinfo = require("objj-fontinfo").fontinfo,
        info = fontinfo("LucidaGrande", 13);
 */
    try {
        child_process.execSync("which fontinfo");
    } catch(error) {
        [self failWithMessage:@"fontinfo does not appear to be installed"];
    }
}

- (void)enumerateFrameworks
{
    var frameworksDirectory = PATH.join(appDirectory, "Frameworks"),
        debugFrameworksDirectory = PATH.join(frameworksDirectory, "Debug");

    [debugFrameworksDirectory, frameworksDirectory].forEach(function(directory)
    {
        if (fs.existsSync(directory) && fs.lstatSync(directory).isDirectory())
        {
            var frameworkList = fs.readdirSync(directory);

            frameworkList.forEach(function(framework)
            {
                if (framework !== @"Debug" && ![frameworks containsKey:framework])
                {
                    var resourceDirectory = PATH.join(directory, framework, "Resources");

                    if (fs.existsSync(resourceDirectory) && fs.lstatSync(resourceDirectory).isDirectory())
                        resourceDirectory = PATH.normalize(resourceDirectory);
                    else
                        resourceDirectory = @"";

                    [frameworks setValue:{resourceDirectory:resourceDirectory, loaded:false} forKey:framework];
                }
            });
        }
    });
}

- (void)convertWithOptions:(JSObject)options inputPath:(CPString)inputPath completionHandler:(Function /* (BOOL) */)completionBlock
{
    try
    {
        inputPath = inputPath || [self getInputPath:options.args];

        [self getAppAndResourceDirectoriesFromInputPath:inputPath options:options];
        [self enumerateFrameworks];

        if (options.readStoredOptions)
        {
            options = [self mergeOptionsWithStoredOptions:options inputPath:inputPath];
            [self setLogLevel:options.quiet ? -1 : options.verbosity];
        }

        if (!options.quiet && options.verbosity > 0)
            [self printVersion];

        var configInfo = [self readConfigFile:options.configFile || @"" inputPath:inputPath],
            outputPath = [self getOutputPathFromInputPath:inputPath args:options.args];
        infoPlist = configInfo.plist;

        if (infoPlist)
        {
            var systemFontFace = [infoPlist valueForKey:@"CPSystemFontFace"];

            if (systemFontFace)
                [CPFont setSystemFontFace:systemFontFace];

            var systemFontSize = [infoPlist valueForKey:@"CPSystemFontSize"];

            if (systemFontSize)
                [CPFont setSystemFontSize:parseFloat(systemFontSize, 10)];
        }
        else
            infoPlist = @{};

        var themeList = [self getThemeList:options];
        [self loadThemesFromList:themeList completionHandler: function() {
            [self loadFrameworks:options.frameworks verbosity:options.verbosity];

            var mainBundle = [CPBundle mainBundle];
            [mainBundle loadWithDelegate:nil];
            [self loadNSClassesFromBundle:mainBundle];

            var frameworkList = [];

            [frameworks allKeys].forEach(function(name)
            {
                var info = [frameworks valueForKey:name];

                if (info.resourceDirectory)
                    name += "*";

                if (info.loaded)
                    name += "+";

                frameworkList.push(name);
            });

            CPLog.info("\n-------------------------------------------------------------");
            CPLog.info("Input         : " + inputPath);
            CPLog.info("Output        : " + outputPath);
            CPLog.info("Application   : " + appDirectory);
            CPLog.info("Resources     : " + appResourceDirectory);
            CPLog.info("Frameworks    : " + (frameworkList.join(", ") || ""));
            CPLog.info("Default theme : " + themeList[0]);
            CPLog.info("Aux themes    : " + themeList.slice(1).join(", "));
            CPLog.info("Config file   : " + (configInfo.path || ""));
            CPLog.info("System Font   : " + [CPFont systemFontSize] + "px " + [CPFont systemFontFace]);
            CPLog.info("NSClasses     : " + userNSClasses);

            CPLog.info("-------------------------------------------------------------\n");

            var converter = [[Converter alloc] initWithInputPath:inputPath outputPath:outputPath];
            [converter convert];

            completionBlock(YES);
        }];

    }
    catch (anException)
    {
        [self logError:[self exceptionReason:anException]];
        return NO;
    }
}

- (void)watchWithOptions:(JSObject)options
{
    var verbosity = options.quiet ? -1 : options.verbosity,
        watchDir = options.args[0];

    if (!watchDir)
        watchDir = PATH.normalize((fs.existsSync("Resources") && fs.lstatSync("Resources").isDirectory()) ? "Resources" : ".");
    else
    {
        watchDir = PATH.normalize(watchDir);

        if (PATH.basename(watchDir) !== "Resources")
        {
            var path = PATH.join(watchDir, "Resources");
            
            if (fs.lstatSync(path).isDirectory())
                watchDir = path;
        }
    }

    if (!fs.lstatSync(watchDir).isDirectory())
        [self failWithMessage:@"Cannot find the directory: " + watchDir];

    // Turn on info messages
    [self setLogLevel:1];

    var nibs = new FileList(PATH.join(watchDir, "*.[nx]ib")).items(),
        count = nibs.length;

    // First time through only IB files with no corresponding cib
    // or a cib with an earlier or equal mtime are converted.
    while (count--)
    {
        var nib = nibs[count],
            cib = nib.substr(0, nib.length - 4) + ".cib";
        
        if (fs.existsSync(cib) && (fs.lstatSync(nib).mtime-fs.lstatSync(cib).mtime) <= 0)
            nibInfo[nib] = fs.lstatSync(nib).mtime;
    }

    CPLog.info("Watching: " + CPLogColorize(watchDir, "debug"));
    CPLog.info("Press Control-C to stop...");

    fs.watch(watchDir, function() {
        var modifiedNibs = [self getModifiedNibsInDirectory:watchDir];
        for (var i = 0; i < modifiedNibs.length; ++i)
        {
            var action = modifiedNibs[i][0],
                nib = modifiedNibs[i][1],
                label = action === "add" ? "Added" : "Modified",
                level = action === "add" ? "info" : "debug";

            CPLog.info(">> %s: %s", CPLogColorize(label, level), nib);

            // Don't convert an add if there is an existing cib with a later mtime
            if (action === "add")
            {
                var cib = nib.substr(0, nib.length - 4) + ".cib";

                if (fs.existsSync(cib) && (fs.lstatSync(nib).mtime-fs.lstatSync(cib).mtime) < 0)
                    continue;
            }

            // Let the converter log however the user configured it
            [self setLogLevel:verbosity];
            
            [self convertWithOptions:options inputPath:nib completionHandler:function(success) { }];
        }
    });
}

- (JSObject)parseOptionsFromArgs:(CPArray)theArgs
{
    parser.usage("[--watch DIRECTORY] [INPUT_FILE [OUTPUT_FILE]]");

    parser.option("--watch", "watch")
        .set(true)
        .help("Ask nib2cib to watch a directory for changes");

    parser.option("--default-theme", "defaultTheme")
        .set()
        .displayName("name")
        .help("Specify a custom default theme which is not set in your Info.plist");

    parser.option("-t", "--theme", "auxThemes")
        .push()
        .displayName("name")
        .help("An additional theme loaded dynamically by your application");

    parser.option("--config", "configFile")
        .set()
        .displayName("path")
        .help("A path to an Info.plist file from which the system font and/or size can be retrieved");

    parser.option("-v", "--verbose", "verbosity")
        .inc()
        .help("Increase verbosity level");

    parser.option("-q", "--quiet", "quiet")
        .set(true)
        .help("No output");

    parser.option("-F", "--framework", "frameworks")
        .push()
        .help("Add a framework to load");

    parser.option("--no-stored-options", "readStoredOptions")
        .set(false)
        .def(true)
        .help("Do not read stored options");

    parser.option("--no-colors", "noColors")
        .set(true)
        .def(false)
        .help("Don't colorize output");

    parser.option("--version", "showVersion")
        .action(function() { [self printVersionAndExit]; })
        .help("Show the version of nib2cib and quit");

    parser.option("-R", "deprecatedResourcesDir")
        .set()
        .displayName("resources directory")
        .help("This option is deprecated.");

    parser.helpful();

    //var options = { args : theArgs }; //FIXME: parser.parse(theArgs, null, null, true);
    var options = parser.parse(theArgs, null, null, true);
    //options.args = options.args.slice(1);
    if (options.args.length > 2)
    {
        console.log("options.args: " + options.args);
        console.log("options.args.length > 2, will crash");
        //parser.printUsage(options);
        process.exit(0);
    }

    return options;
}

- (JSObject)mergeOptionsWithStoredOptions:(JSObject)options inputPath:(CPString)inputPath
{
    // We have to clone options
    var userOptions = [self readStoredOptionsAtPath:PATH.join(process.env["HOME"], ".nib2cibconfig")],
        appOptions = [self readStoredOptionsAtPath:PATH.join(appDirectory, "nib2cib.conf")],
        filename = PATH.basename(inputPath, PATH.extname(inputPath)) + ".conf",
        fileOptions = [self readStoredOptionsAtPath:PATH.join(PATH.dirname(inputPath), filename)];
        
    // At this point we have an array of args without the initial command in args[0],
    // add the command and parse the options.
    userOptions = [self parseOptionsFromArgs:[options.command].concat(userOptions)];
    appOptions = [self parseOptionsFromArgs:[options.command].concat(appOptions)];
    fileOptions = [self parseOptionsFromArgs:[options.command].concat(fileOptions)];

    // The increasing order of precedence is: user -> app -> file -> command line
    var mergedOptions = userOptions;

    [self mergeOptions:appOptions with:mergedOptions];
    [self mergeOptions:fileOptions with:mergedOptions];
    [self mergeOptions:options with:mergedOptions];
    mergedOptions.args = options.args;

    return mergedOptions;
}

- (CPArray)readStoredOptionsAtPath:(CPString)path
{
    path = PATH.normalize(path);

/*     if (!FILE.isReadable(path))
        return [];
 */
    try {
        fs.accessSync(path, fs.constants.R_OK);
    } catch (err) {
        return []; 
    }

    // reading the whole file into memory, could be problematic
    var file = fs.readFileSync(path, { encoding: "utf8" });
    var line = file.split("\n")[0];
    var matches = line.match(ArgsRe) || [];

/*     var file = FILE.open(path, "r"),
        line = file.readLine(),
        matches = line.match(ArgsRe) || []; */

    file.close();
    CPLog.debug("Reading stored options: " + path);

    if (matches)
    {
        for (var i = 0; i < matches.length; ++i)
        {
            var str = matches[i];

            if ((str.charAt(0) === '"' && str.substr(-1) === '"') || (str.charAt(0) === "'" && str.substr(-1) === "'"))
                matches[i] = str.substr(1, str.length - 2);
        }

        return matches;
    }
    else
        return [];
}

- (void)printOptions:options
{
    var option;

    for (option in options)
    {
        var value = options[option];

        if (value)
        {
            var show = value.length !== undefined ? value.length > 0 : !!value;

            if (show)
                console.log(option + ": " + value);
        }
    }
}

// Merges properties in sourceOptions into targetOptions, overriding properties in targetOptions
- (void)mergeOptions:(JSObject)sourceOptions with:(JSObject)targetOptions
{
    var option;

    for (option in sourceOptions)
    {
        // Make sure only a supported option is given
        if (!AllowedStoredOptionsRe.test(option))
            continue;

        if (sourceOptions.hasOwnProperty(option))
        {
            var value = sourceOptions[option];

            if (value)
            {
                var copy = value.length !== undefined ? value.length > 0 : !!value;

                if (copy)
                    targetOptions[option] = value;
            }
        }
    }
}

- (void)setLogLevel:(int)level
{
    CPLogUnregister(CPLogPrint);

    if (level === 0)
        CPLogRegister(CPLogPrint, "warn", logFormatter);
    else if (level === 1)
        CPLogRegister(CPLogPrint, "info", logFormatter);
    else if (level > 1)
        CPLogRegister(CPLogPrint, null, logFormatter);
}

- (CPString)getInputPath:(CPArray)theArgs
{
    var inputPath = theArgs[0] || DefaultFile,
        path = "";

    if (!/^.+\.[nx]ib$/.test(inputPath))
    {
        if (path = [self findInputPath:inputPath extension:@".xib"])
            inputPath = path;
        else if (path = [self findInputPath:inputPath extension:@".nib"])
            inputPath = path;
        else
            [self failWithMessage:@"Cannot find the input file (.xib or .nib): " + PATH.normalize(inputPath)];
    }
    else if (path = [self findInputPath:inputPath extension:nil])
        inputPath = path;
    else
        [self failWithMessage:@"Could not read the input file: " + PATH.normalize(inputPath)];

    return PATH.resolve(inputPath);
}

- (void)findInputPath:(CPString)inputPath extension:(CPString)extension
{
    var path = inputPath;

    if (extension)
        path += extension;

    try {
        fs.accessSync(path, fs.constants.R_OK);
        return path;
    } catch (err) {
        // is not readable
    }

/*     if (FILE.isReadable(path))
        return path; */
    
    if (PATH.basename(PATH.dirname(inputPath)) !== "Resources" && fs.lstatSync("Resources").isDirectory())
    {
        path = PATH.resolve(path, PATH.join("Resources", PATH.basename(path)));

        try {
            fs.accessSync(path, fs.constants.R_OK);
            return path;
        } catch (err) {
            // is not readable
        }

/* 
        if (FILE.isReadable(path))
            return path; */
    }

    return null;
}

- (void)getAppAndResourceDirectoriesFromInputPath:(CPString)aPath options:(JSObject)options
{
    appDirectory = @"";

    var parentDir = PATH.dirname(aPath),
        match = /^(.+)(\/Resources(?:\/.+)?)$/.exec(parentDir);

    if (match)
    {
        appDirectory = match[1];
        appResourceDirectory = PATH.join(appDirectory, "Resources");
    }
    else
    {
        appDirectory = parentDir;

        if (!appResourceDirectory)
        {
            var path = PATH.join(appDirectory, "Resources");
            
            if (fs.existsSync(path) && fs.lstatSync(path, { throwIfNoEntry: false }).isDirectory())
                appResourceDirectory = path;
        }
    }
}

- (CPString)getOutputPathFromInputPath:(CPString)aPath args:(CPArray)theArgs
{
    var outputPath = null;

    if (theArgs.length > 1)
    {
        outputPath = theArgs[1];

        if (!/^.+\.cib$/.test(outputPath))
            outputPath += ".cib";
    }
    else
        outputPath = PATH.join(PATH.dirname(aPath), PATH.basename(aPath, PATH.extname(aPath))) + ".cib";

    outputPath = PATH.normalize(outputPath);

    try {
        fs.accessSync(PATH.dirname(outputPath), fs.constants.W_OK);
    } catch(err) {
        [self failWithMessage:@"Cannot write the output file at: " + outputPath];
    }

/*     if (!FILE.isWritable(FILE.dirname(outputPath)))
        [self failWithMessage:@"Cannot write the output file at: " + outputPath];
 */
    return outputPath;
}

- (void)loadFrameworks:(CPArray)frameworksToLoad verbosity:(int)verbosity
{
    if (!frameworksToLoad || frameworksToLoad.length === 0)
        return;

    frameworksToLoad.forEach(function(aFramework)
    {
        [self setLogLevel:verbosity];

        var frameworkPath = nil;

        // If it is just a name with no path components, try to locate it
        if (aFramework.indexOf("/") === -1)
        {
            frameworkPath = [self findInFrameworks:PATH.join(appDirectory, "Frameworks")
                                              path:aFramework
                                       isDirectory:YES
                                          callback:function(path) { return path; }];
        }
        else
            [self failWithMessage:@"-F should be used only with a framework name that is in the app's Framework directory"];

        if (!frameworkPath)
            [self failWithMessage:@"Cannot find the framework \"" + aFramework + "\""];

        CPLog.debug("Loading framework: " + frameworkPath);

        try
        {
            // CPBundle is a bit loquacious with logging, we will defer
            // logging its exceptions till later.
            [self setLogLevel:-1];

            var frameworkBundle = [[CPBundle alloc] initWithPath:frameworkPath];

            [frameworkBundle loadWithDelegate:nil];
            [self setLogLevel:verbosity];

            [self loadNSClassesFromBundle:frameworkBundle];

            var frameworkName = PATH.basename(frameworkPath),
                info = [frameworks valueForKey:frameworkName];

            info.loaded = true;
        }
        finally
        {
            [self setLogLevel:verbosity];
        }

        //require("browser/timeout").serviceTimeouts();
    });
}

- (void)loadNSClassesFromBundle:(CPBundle)aBundle
{
    // See if the framework defines NS classes
    var nsClasses = [aBundle objectForInfoDictionaryKey:@"NSClasses"] || [],
        bundlePath = [aBundle bundlePath];

    for (var i = 0; i < nsClasses.length; ++i)
    {
        if (userNSClasses.indexOf(nsClasses[i]) >= 0)
            continue;

        var path = PATH.join(bundlePath, "NS_" + nsClasses[i] + ".j");

        objj_importFile(path, YES);
        CPLog.debug("Imported NS class: %s", path);

        userNSClasses.push(nsClasses[i]);
    }
}

- (CPArray)getThemeList:(JSObject)options
{
    var defaultTheme = options.defaultTheme;

    if (!defaultTheme)
        defaultTheme = [infoPlist valueForKey:@"CPDefaultTheme"];

    if (!defaultTheme)
        defaultTheme = [self getAppKitDefaultThemeName];

    var themeList = [CPSet setWithObject:defaultTheme];

    if (options.auxThemes)
        [themeList addObjectsFromArray:options.auxThemes];

    var auxThemes = infoPlist.valueForKey("CPAuxiliaryThemes");

    if (auxThemes)
        [themeList addObjectsFromArray:auxThemes];

    // Now remove the default theme, get the list as an array, and insert the default at the beginning
    [themeList removeObject:defaultTheme];

    var allThemes = [themeList allObjects];

    [allThemes insertObject:defaultTheme atIndex:0];

    return allThemes;
}

// Returns undefined if $CAPP_BUILD is not defined, false if path cannot be found in $CAPP_BUILD
- (id)findInCappBuild:(CPString)path isDirectory:(BOOL)isDirectory callback:(JSObject)callback
{
    var cappBuild = process.env["CAPP_BUILD"];

    if (!cappBuild)
        return undefined;

    cappBuild = PATH.normalize(cappBuild);

    if (fs.existsSync(cappBuild) && fs.lstatSync(cappBuild).isDirectory())
    {
        var result = null;

        for (var i = 0; i < BuildTypes.length && !result; ++i)
        {
            var findPath = PATH.join(cappBuild, BuildTypes[i], path);

            if ((isDirectory && fs.lstatSync(findPath).isDirectory()) || (!isDirectory && fs.existsSync(findPath)))
                result = callback(findPath);
        }

        return result;
    }
    else
        return false;
}

- (id)findInInstalledFrameworks:(CPString)path isDirectory:(BOOL)isDirectory callback:(JSObject)callback
{
    // NOTE: It's safe to use '/' directly in the path, we're guaranteed to be on a Mac
    // FIXME: temporary fix, narwhal will not be used in the future
    return [self findInFrameworks:PATH.normalize(PATH.resolve(fs.realpathSync(process.argv[1]), "..", "..", "Frameworks"))
                             path:path
                      isDirectory:isDirectory
                         callback:callback];
}

- (id)findInFrameworks:(CPString)frameworksPath path:(CPString)path isDirectory:(BOOL)isDirectory callback:(JSObject)callback
{
    var result = null,
        findPath = PATH.join(frameworksPath, "Debug", path);

    if ((isDirectory && fs.lstatSync(findPath).isDirectory()) || (!isDirectory && fs.existsSync(findPath)))
        result = callback(findPath);

    if (!result)
    {
        findPath = PATH.join(frameworksPath, path);

        if ((isDirectory && fs.lstatSync(findPath).isDirectory()) || (!isDirectory && fs.existsSync(findPath)))
            result = callback(findPath);
    }

    return result;
}

- (CPString)getAppKitDefaultThemeName
{
    var callback = function(path) { return [self themeNameFromPropertyList:path]; },
        themeName = [self findInCappBuild:@"AppKit/Info.plist" isDirectory:NO callback:callback];

    if (!themeName)
        themeName = [self findInInstalledFrameworks:@"AppKit/Info.plist" isDirectory:NO callback:callback];

    return themeName || DefaultTheme;
}

- (CPString)themeNameFromPropertyList:(CPString)path
{
    try {
        fs.accessSync(path, fs.constants.R_OK);
    } catch (error) {
        return nil;
    }
/*     if (!FILE.isReadable(path))
        return nil; */

    var themeName = nil,
        plist = CFPropertyList.readPropertyListFromFile(path);

    if (plist)
        themeName = plist.valueForKey("CPDefaultTheme");

    return themeName;
}

- (void)loadThemesFromList:(CPArray)themeList completionHandler:(Function)completionBlock
{
    var nLoadedThemes = themeList.length;
    themes.length = themeList.length;

    [themeList enumerateObjectsUsingBlock: function(themeName, i) {
        [self loadThemeNamed:themeName completionHandler: function(theme) {
            themes[i] = theme;
            nLoadedThemes--;
            if (nLoadedThemes === 0) {
                completionBlock();
            }
        }];
    }];
}

- (void)loadThemeNamed:(CPString)themeName completionHandler:(Function/* (CPTheme) */)completionBlock
{
    if (/^.+\.blend$/.test(themeName))
        themeName = themeName.substr(0, themeName.length - ".blend".length);

    var blendName = themeName + ".blend",
        themePath = "",
        themeDir = appResourceDirectory;

    if (themeDir)
    {
        themePath = PATH.join(PATH.normalize(themeDir), blendName);
    
        if (!fs.existsSync(themePath) || !fs.lstatSync(themePath).isDirectory())
            themePath = themeDir = null;
    }

    if (!themeDir)
    {
        var returnPath = function(path) { return path; };

        themePath = [self findInCappBuild:blendName isDirectory:YES callback:returnPath];

        if (!themePath)
            themePath = [self findInInstalledFrameworks:@"AppKit/Resources/" + blendName isDirectory:YES callback:returnPath];

        // Last resort, try the cwd
        if (!themePath)
        {
            var path = PATH.normalize(blendName);

            if (fs.existsSync(path) && fs.lstatSync(path).isDirectory())
                themePath = path;
        }
    }

    if (!themePath)
        [self failWithMessage:@"Cannot find the theme \"" + themeName + "\""];

    [self readThemeWithName:themeName atPath:themePath completionHandler:completionBlock];
}

- (void)readThemeWithName:(CPString)name atPath:(CPString)path completionHandler:(Function /* (CPTheme) */)completionBlock
{
    var themeBundle = new CFBundle(path);

    // By default when we try to load the bundle it will use the CommonJS environment,
    // but we want the Browser environment. So we override mostEligibleEnvironment().
    themeBundle.mostEligibleEnvironment = function() { return "Browser"; };

    var loadFunction = function()
    {
        var keyedThemes = themeBundle.valueForInfoDictionaryKey("CPKeyedThemes");

        if (!keyedThemes)
            [self failWithMessage:@"Could not find the keyed themes in the theme: " + path];

        var index = keyedThemes.indexOf(name + ".keyedtheme");

        if (index < 0)
            [self failWithMessage:@"Could not find the main theme data (" + name + ".keyedtheme" + ") in the theme: " + path];

        // Load the keyed theme data, making sure to resolve it
        var resourcePath = themeBundle.pathForResource(keyedThemes[index]),
            themeData = new CFMutableData();

        themeData.setRawString(StaticResource.resourceAtURL(new CFURL(resourcePath), true).contents());

        var theme = [CPKeyedUnarchiver unarchiveObjectWithData:themeData];

        if (!theme)
            [self failWithMessage:@"Could not unarchive the theme at: " + path];

        CPLog.debug("Loaded theme: " + path);
        completionBlock(theme);
    };

    if (themeBundle.isLoaded()) {
        loadFunction();
    } else {
        themeBundle.addEventListener("load", loadFunction);

        themeBundle.addEventListener("error", function()
        {
            CPLog.error("Could not find bundle: " + themeBundle);
        });

        themeBundle.load();
    }
}

- (JSObject)readConfigFile:(CPString)configFile inputPath:(CPString)inputPath
{
    var configPath = null,
        path;

    // First see if the user passed a config file path
    if (configFile)
    {
        path = PATH.normalize(configFile);
        
        try {
            fs.accessSync(path, fs.constants.R_OK);
        } catch (error) {
            [self failWithMessage:@"Cannot find the config file: " + path];
        }

/*         if (!FILE.isReadable(path))
            [self failWithMessage:@"Cannot find the config file: " + path];
 */
        configPath = path;
    }
    else
    {
        path = PATH.join(appDirectory, "Info.plist");

        try {
            fs.accessSync(path, fs.constants.R_OK);
            configPath = path;
        } catch (error) {
            // is not readable
        }

/*         if (FILE.isReadable(path))
            configPath = path;
 */ }

    var plist = null;

    if (configPath)
    {
        var plist = fs.readFileSync(configPath, { encoding: "utf8" });
        //var plist = FILE.read(configPath);

        if (!plist)
            [self failWithMessage:@"Could not read the Info.plist at: " + configPath];

        if (plist.trim().length > 0) {
            plist = CFPropertyList.propertyListFromString(plist);

            if (!plist)
                [self failWithMessage:@"Could not parse the Info.plist at: " + configPath];
        } else {
            plist = nil;
        }
    }

    return {path: configPath, plist: plist};
}

- (CPArray)getModifiedNibsInDirectory:(CPString)path
{
    var nibs = new FileList(PATH.join(path, "*.[nx]ib")).items(),
        count = nibs.length,
        newNibInfo = {},
        modifiedNibs = [];

    while (count--)
    {
        var nib = nibs[count];

        newNibInfo[nib] = fs.lstatSync(nib).mtime;

        if (!nibInfo.hasOwnProperty(nib))
            modifiedNibs.push(["add", nib]);
        else
        {
            if (newNibInfo[nib] - nibInfo[nib] !== 0)
                modifiedNibs.push(["mod", nib]);

            // Remove matching nibs so that we leave
            // deleted nibs in nibInfo.
            delete nibInfo[nib];
        }
    }

    for (var nib in nibInfo)
        if (nibInfo.hasOwnProperty(nib))
            CPLog.info(">> %s: %s", CPLogColorize("Deleted", "warn"), nib);

    nibInfo = newNibInfo;

    return modifiedNibs;
}

- (void)printVersionAndExit
{
    [self printVersion];
    process.exit(0);
}

- (void)printVersion
{
    var path = PATH.join(fs.realpathSync(process.argv[1]), "..", "..", "lib", "nib2cib", "Info.plist");
    var version = null;
    
    try {
        fs.accessSync(path, fs.constants.R_OK);

        var plist = fs.readFileSync(path, { encoding: "utf8" });

        if (!plist)
            return;

        plist = CFPropertyList.propertyListFromString(plist);

        if (!plist)
            return;

        version = plist.valueForKey("CPBundleVersion");

        if (version) {
            stream.print("nib2cib v" + version);
        }
    } catch (error) {
        console.log("Error: " + path + " is not readable.");
    }

    if (!version) {
        stream.print("<No version info available>");
    }
}

- (CPString)exceptionReason:(JSObject)exception
{
    if (typeof(exception) === "string")
        return exception;
    else if (exception.isa && [exception respondsToSelector:@selector(reason)])
        return [exception reason];
    else
        return @"An unknown error occurred";
}

- (void)failWithMessage:(CPString)message
{
    [CPException raise:ConverterConversionException reason:message];
}

- (void)logError:(CPString)message
{
    if (Nib2CibColorizeOutput)
        message = CPLogColorize(message, "fatal");

    stream.printError(message);
}

- (void)bundleDidFinishLoading:(CPBundle)aBundle
{
}

@end

function logFormatter(aString, aLevel, aTitle)
{
    if (!Nib2CibColorizeOutput || aLevel === "info")
        return aString;
    else
        return CPLogColorize(aString, aLevel);
}
