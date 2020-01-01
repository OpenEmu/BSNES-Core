/*
 Copyright (c) 2012, OpenEmu Team
 

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <OpenGL/gl.h>
#import "BSNESGameCore.h"
#import "OESNESSystemResponderClient.h"

#define SYS_PARAM_H__BSD BSD
#undef BSD

#include "program.mm"


/*
 * TODO
 *  - Multitap support
 *  - Mouse support
 *  - Add support for 64 bit pixel formats to the Metal renderer in OpenEmu and remove
 *    the 64 bit -> 32 bit pixel format conversion in Program::videoFrame()
 */


@implementation BSNESGameCore {
    NSMutableSet <NSString *> *_activeCheats;
    NSMutableDictionary <NSString *, NSNumber *> *_displayModes;
}

- (id)init
{
    self = [super init];
    emulator = new SuperFamicom::Interface;
    program = new Program(self);
    _activeCheats = [[NSMutableSet alloc] init];
    _displayModes = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc
{
    delete emulator;
    delete program;
}


#pragma mark - Configuration & Cheats


- (void)setDisplayModeInfo:(NSDictionary<NSString *,id> *)displayModeInfo
{
    _displayModes = [@{
        @"bsnes/Video/BlurEmulation": @NO,
        @"bsnes/Video/ColorEmulation": @YES,
        @"bsnes/Hacks/PPU/NoSpriteLimit": @NO,
        @"hide_overscan": @YES
    } mutableCopy];
    [_displayModes addEntriesFromDictionary:displayModeInfo];
}

- (NSDictionary<NSString *,id> *)displayModeInfo
{
    return [_displayModes copy];
}

- (NSArray<NSDictionary<NSString *,id> *> *)displayModes
{
    return @[
        OEDisplayMode_OptionToggleableWithState(@"Blur Emulation",
            @"bsnes/Video/BlurEmulation", _displayModes[@"bsnes/Video/BlurEmulation"]),
        OEDisplayMode_OptionToggleableWithState(@"Color Emulation",
            @"bsnes/Video/ColorEmulation", _displayModes[@"bsnes/Video/ColorEmulation"]),
        OEDisplayMode_OptionToggleableWithState(@"Hide Overscan",
            @"hide_overscan", _displayModes[@"hide_overscan"]),
        OEDisplayMode_SeparatorItem(),
        OEDisplayMode_OptionToggleableWithState(@"Disable Sprite Limit (requires reset)",
            @"bsnes/Hacks/PPU/NoSpriteLimit", _displayModes[@"bsnes/Hacks/PPU/NoSpriteLimit"]),
    ];
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
    NSString *key = OEDisplayModeListGetPrefKeyFromModeName(self.displayModes, displayMode);
    NSNumber *currentVal = _displayModes[key];
    _displayModes[key] = @(!(currentVal.boolValue));
    [self configEmulator];
}

- (void)configEmulator
{
    emulator->configure("Hacks/Hotfixes", true);
    emulator->configure("Hacks/PPU/Fast", true);
    [_displayModes enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *obj, BOOL *stop) {
        if ([key hasPrefix:@"bsnes/"]) {
            NSString *keyNoPrefix = [key substringFromIndex:@"bsnes/".length];
            emulator->configure(keyNoPrefix.UTF8String, (bool)(obj.boolValue));
        }
    }];
    program->overscan = !(_displayModes[@"hide_overscan"].boolValue);
}

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    if ([type isEqual:@"Action Replay"])
        code = [code stringByReplacingOccurrencesOfString:@":" withString:@""];
    NSArray <NSString *> *codes = [code componentsSeparatedByString:@"+"];
    if (enabled)
        [_activeCheats addObjectsFromArray:codes];
    else
        [_activeCheats minusSet:[NSSet setWithArray:codes]];
    [self loadCheats];
}

- (void)loadCheats
{
    vector<string> newCheatList;
    for (NSString *cheat in _activeCheats) {
        string decodedCheat = string(cheat.UTF8String).downcase();
        if (OEBSNESCheatDecodeSNES(decodedCheat)) {
            NSLog(@"Successfully decoded cheat %@ to %s", cheat, decodedCheat.begin());
            newCheatList.append(decodedCheat);
        } else {
            NSLog(@"Could not decode cheat %@", cheat);
        }
    }
    emulator->cheats(newCheatList);
}


#pragma mark - Load / Save


- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    memset(pad, 0, sizeof(pad));
    [self configEmulator];
    
    const char *fullPath = path.fileSystemRepresentation;
    program->superFamicom.location = string(fullPath);
    program->base_name = string(fullPath);
    program->load();
    
    if (program->failedLoadingAtLeastOneRequiredFile) {
        NSError *outErr;
        if (program->lastFailedBiosLoad) {
            NSString *missing = [NSString stringWithUTF8String:program->lastFailedBiosLoad.get().begin()];
            NSError *outErr = [NSError
                errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError
                userInfo:@{
                    NSLocalizedDescriptionKey: @"Required chip dump file missing.",
                    NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:
                        @"To run this game you need the following file:\n"
                        @"\"%@\"\n\n"
                        @"Obtain this file, drag and drop onto the game library "
                        @"window and try again.", missing]}];
        }
        if (error)
            *error = outErr;
        return NO;
    }
    
    emulator->connect(SuperFamicom::ID::Port::Controller1, SuperFamicom::ID::Device::Gamepad);
    emulator->connect(SuperFamicom::ID::Port::Controller2, SuperFamicom::ID::Device::Gamepad);
    [self loadCheats];
    
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    NSAssert(batterySavesDirectory.length > 0, @"no battery save directory!?");
    [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    
    return YES;
}

- (NSData *)serializeStateWithError:(NSError *__autoreleasing *)outError
{
    serializer s = emulator->serialize();
    return [NSData dataWithBytes:s.data() length:s.size()];
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError *__autoreleasing *)outError
{
    serializer s(static_cast<const uint8_t *>(state.bytes), (uint)state.length);
    BOOL res = emulator->unserialize(s);
    if (!res && outError)
        *outError = [NSError
            errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError
            userInfo:@{ NSLocalizedDescriptionKey : @"The save state data could not be read." }];
    return res;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    NSData *stateData = [self serializeStateWithError:nil];
    
    __autoreleasing NSError *error = nil;
    BOOL success = [stateData writeToFile:fileName options:NSDataWritingAtomic error:&error];
    
    block(success, success ? nil : error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    __autoreleasing NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:fileName options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];
    
    if(data == nil) {
        block(NO, error);
        return;
    }
    
    BOOL success = [self deserializeState:data withError:&error];
    block(success, success ? nil : error);
}


#pragma mark - Input


- (oneway void)didPushSNESButton:(OESNESButton)button forPlayer:(NSUInteger)player;
{
    NSAssert(player > 0 && player <= 2, @"too many players");
    pad[player-1][button] = YES;
}

- (oneway void)didReleaseSNESButton:(OESNESButton)button forPlayer:(NSUInteger)player;
{
    NSAssert(player > 0 && player <= 2, @"too many players");
    pad[player-1][button] = NO;
}

- (oneway void)leftMouseDownAtPoint:(OEIntPoint)point
{
}

- (oneway void)leftMouseUp
{
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)point
{
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point
{
}

- (oneway void)rightMouseUp
{
}


#pragma mark - Execution


- (void)executeFrame
{
    emulator->run();
}

- (void)resetEmulation
{
    emulator->reset();
}

- (void)stopEmulation
{
    program->save();
    [super stopEmulation];
}


#pragma mark - Video


- (const void *)getVideoBufferWithHint:(void *)hint
{
    NSAssert(hint, @"no hint? bummer");
    videoBuffer = (uint32_t *)hint;
    return hint;
}

- (OEIntRect)screenRect
{
    return screenRect;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(512, 480);
}

- (OEIntSize)aspectSize
{
    if (!(program->overscan)) {
        /* Overscan hiding removes the top and bottom 8 pixels.
         * This fraction is equivalent to (256 * 8 / 7) / 224 */
        return OEIntSizeMake(64, 49);
    }
    return OEIntSizeMake(8, 7);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

- (NSTimeInterval)frameInterval
{
    if (program->superFamicom.region == "NTSC") {
        return 21477272.0 / 357366.0;
    }
    return 21281370.0 / 425568.0;
}


#pragma mark - Audio


- (double)audioSampleRate
{
    return Emulator::audio.frequency();
}

- (NSUInteger)channelCount
{
    return Emulator::audio.channels();
}


@end
