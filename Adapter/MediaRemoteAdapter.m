// Streams the system-wide Now Playing state as JSON lines on stdout and reads
// playback commands from stdin.
//
// Since macOS 15.4, MediaRemote only answers processes with an Apple entitlement.
// /usr/bin/perl has it, so the app runs this library inside perl (see
// MediaRemoteAdapter.pl) instead of calling MediaRemote itself.
//
// stdin commands, one per line: "toggle", "play", "pause", "next", "previous", "seek <seconds>".
// The process exits when stdin closes, i.e. when the app quits.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientStringFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

enum { kPlay = 0, kPause = 1, kTogglePlayPause = 2, kNextTrack = 4, kPreviousTrack = 5 };

static void *mediaRemote;
static dispatch_queue_t queue;
static NSData *lastArtwork;
static BOOL sentArtwork;

static void *symbol(const char *name) { return dlsym(mediaRemote, name); }

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void finish(NSMutableDictionary *out) {
    GetClientFn getClient = symbol("MRMediaRemoteGetNowPlayingClient");
    ClientStringFn parentID = symbol("MRNowPlayingClientGetParentAppBundleIdentifier");
    ClientStringFn bundleID = symbol("MRNowPlayingClientGetBundleIdentifier");
    if (!getClient) {
        emit(out);
        return;
    }
    getClient(queue, ^(id client) {
        NSString *identifier = (client && parentID) ? parentID(client) : nil;
        if (identifier.length == 0 && client && bundleID) identifier = bundleID(client);
        if (identifier.length > 0) out[@"bundleIdentifier"] = identifier;
        emit(out);
    });
}

static void emitEmpty(void) {
    lastArtwork = nil;
    sentArtwork = NO;
    emit(@{ @"empty": @YES });
}

static void update(void) {
    GetInfoFn getInfo = symbol("MRMediaRemoteGetNowPlayingInfo");
    GetIsPlayingFn getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!getInfo) return;

    getInfo(queue, ^(NSDictionary *info) {
        NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        if (title.length == 0) {
            // Untitled media (e.g. a bare audio file in a browser): report it only while it
            // plays, so the app can show the player's name instead of "Nothing playing".
            if (!getIsPlaying) {
                emitEmpty();
                return;
            }
            getIsPlaying(queue, ^(Boolean playing) {
                if (!playing) {
                    emitEmpty();
                    return;
                }
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"title"] = @"";
                out[@"playing"] = @YES;
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                out[@"timestamp"] = @([NSDate date].timeIntervalSince1970);
                finish(out);
            });
            return;
        }

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"title"] = title;
        out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
        out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
        out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
        out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
        out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
        NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        out[@"timestamp"] = @((timestamp ?: [NSDate date]).timeIntervalSince1970);

        // Artwork is only sent when it changes, to keep the stream small.
        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (!sentArtwork || !(artwork == lastArtwork || [artwork isEqualToData:lastArtwork])) {
            out[@"artwork"] = artwork ? [artwork base64EncodedStringWithOptions:0] : @"";
            lastArtwork = artwork;
            sentArtwork = YES;
        }

        if (getIsPlaying) {
            getIsPlaying(queue, ^(Boolean playing) {
                out[@"playing"] = @(playing);
                finish(out);
            });
        } else {
            out[@"playing"] = @([out[@"rate"] doubleValue] > 0);
            finish(out);
        }
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    if ([command isEqualToString:@"seek"] && parts.count > 1) {
        SetElapsedFn setElapsed = symbol("MRMediaRemoteSetElapsedTime");
        if (setElapsed) setElapsed(parts[1].doubleValue);
        return;
    }
    NSDictionary *commands = @{
        @"toggle": @(kTogglePlayPause), @"play": @(kPlay), @"pause": @(kPause),
        @"next": @(kNextTrack), @"previous": @(kPreviousTrack),
    };
    NSNumber *code = commands[command];
    SendCommandFn send = symbol("MRMediaRemoteSendCommand");
    if (code && send) send(code.intValue, nil);
}

static void readCommands(void) {
    static NSMutableData *buffer;
    buffer = [NSMutableData data];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char chunk[1024];
        ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
        if (count <= 0) exit(0);
        [buffer appendBytes:chunk length:(NSUInteger)count];
        NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i + 1 < lines.count; i++) {
            NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length > 0) handleCommand(line);
        }
        buffer = [[lines.lastObject dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    });
    dispatch_resume(source);
    // Keep the source alive for the life of the process.
    static dispatch_source_t retained;
    retained = source;
}

// Called by perl as an XSUB; the arguments (interpreter, CV) are unused. Never returns.
__attribute__((visibility("default")))
void notch_adapter_stream(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;
    @autoreleasepool {
        mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!mediaRemote) {
            fprintf(stderr, "MediaRemote unavailable\n");
            exit(1);
        }
        queue = dispatch_queue_create("NotchUtility.MediaRemoteAdapter", DISPATCH_QUEUE_SERIAL);

        RegisterFn registerForNotifications = symbol("MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerForNotifications) registerForNotifications(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                update();
            }];
        }

        readCommands();
        update();
    }
    CFRunLoopRun();
    exit(0);
}
