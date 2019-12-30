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


@implementation BSNESGameCore {
    NSString *romName;
}


- (id)init
{
    self = [super init];
    emulator = new SuperFamicom::Interface;
    program = new Program(self);
    [self configEmulator];
    return self;
}

- (void)configEmulator
{
    emulator->configure("Hacks/Hotfixes", true);
    emulator->configure("Hacks/CPU/FastMath", true);
    emulator->configure("Hacks/PPU/Fast", true);
    emulator->configure("Video/BlurEmulation", false);
    program->overscan = false;
}

- (void)dealloc
{
    delete emulator;
    delete program;
}


#pragma mark - Load / Save


- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    memset(pad, 0, sizeof(pad));
    romName = [path copy];
    
    const char *fullPath = path.fileSystemRepresentation;
    program->superFamicom.location = string(fullPath);
    program->base_name = string(fullPath);
    program->load();
    
    emulator->connect(SuperFamicom::ID::Port::Controller1, SuperFamicom::ID::Device::Gamepad);
    emulator->connect(SuperFamicom::ID::Port::Controller2, SuperFamicom::ID::Device::Gamepad);
    
    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];
    
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    if([batterySavesDirectory length] != 0)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
#if 0
    int serial_size = retro_serialize_size();
    NSMutableData *stateData = [NSMutableData dataWithLength:serial_size];
    
    if(!retro_serialize([stateData mutableBytes], serial_size))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
        block(NO, error);
        return;
    }
    
    __autoreleasing NSError *error = nil;
    BOOL success = [stateData writeToFile:fileName options:NSDataWritingAtomic error:&error];
    
    block(success, success ? nil : error);
#endif
    block(YES, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
#if 0
    __autoreleasing NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:fileName options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];
    
    if(data == nil)
    {
        block(NO, error);
        return;
    }
    
    int serial_size = retro_serialize_size();
    if(serial_size != [data length])
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state has wrong file size.",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the file %@ does not have the right size, %d expected, got: %ld.", fileName, serial_size, [data length]],
        }];
        block(NO, error);
        return;
    }
    
    if(!retro_unserialize([data bytes], serial_size))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"Could not read the file state in %@.", fileName]
        }];
        block(NO, error);
        return;
    }
    
    block(YES, nil);
#endif
    block(YES, nil);
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
/*
    NSString *path = romName;
    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];
    
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    
    if([batterySavesDirectory length] != 0)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        
        NSLog(@"Trying to save SRAM");
        
        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
        
        writeSaveFile([filePath UTF8String], RETRO_MEMORY_SAVE_RAM);
    }
    
    NSLog(@"snes term");
    retro_unload_game();
    retro_deinit();
    */
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
    return OEIntSizeMake(256 * (8.0/7.0), screenRect.size.height);
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
