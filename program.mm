#include <emulator/emulator.hpp>
#include <sfc/interface/interface.hpp>
using namespace nall;

#include <heuristics/heuristics.hpp>
#include <heuristics/heuristics.cpp>
#include <heuristics/super-famicom.cpp>

/* This file is mostly lifted from bsnes/target-libretro/program.cpp, which
* in turn was mostly lifted from bsnes/target-bsnes/program/program.cpp and
* its plethora of includes.
*   It is a good idea to keep the common parts of this file in sync with its
* target-libretro and target-bsnes counterparts when the core gets updated. */


#pragma mark - Globals


/* The actual SFC emulator object. Communicates to the front-end (an instance
 * of Emulator::Platform) through the Emulator::platform global variable.
 * Owned by BSNESGameCore */
static Emulator::Interface *emulator;

/* The current instance of Emulator::Platform
 * Owned by BSNESGameCore */
struct Program;
static Program *program = nullptr;


#define OE_MODE7_MAX_HIRES         (8)
#define OE_VIDEO_BUFFER_SIZE_W     (512 * OE_MODE7_MAX_HIRES)
#define OE_VIDEO_BUFFER_SIZE_H     (480 * OE_MODE7_MAX_HIRES)


#pragma mark - Platform Object

struct Program : Emulator::Platform {
    Program(BSNESGameCore *oeCore);
    ~Program() {};
    
    auto open(uint id, string name, vfs::file::mode mode, bool required) -> shared_pointer<vfs::file> override;
    auto load(uint id, string name, string type, vector<string> options = {}) -> Emulator::Platform::Load override;
    auto videoFrame(const uint16* data, uint pitch, uint width, uint height, uint scale) -> void override;
    auto audioFrame(const float* samples, uint channels) -> void override;
    auto inputPoll(uint port, uint device, uint input) -> int16 override;
    auto inputRumble(uint port, uint device, uint input, bool enable) -> void override;
    
    auto load() -> void;
    auto loadFile(string location) -> vector<uint8_t>;
    auto loadSuperFamicom(string location) -> bool;

    auto save() -> void;

    auto openRomSuperFamicom(string name, vfs::file::mode mode) -> shared_pointer<vfs::file>;
    auto loadSuperFamicomFirmware(string fwname) -> void;
    
    auto hackCompatibility() -> void;
    auto hackPatchMemory(vector<uint8_t>& data) -> void;
    
    auto updateVideoPalette() -> void;
    
    __weak BSNESGameCore *oeCore;
    string base_name;
    
    bool overscan = false;
    
    maybe<string> lastFailedBiosLoad;
    bool failedLoadingAtLeastOneRequiredFile;

public:
    struct Game {
        explicit operator bool() const { return (bool)location; }
        
        string option;
        string location;
        string manifest;
        Markup::Node document;
        boolean patched;
        boolean verified;
    };

    struct SuperFamicom : Game {
        string title;
        string region;
        vector<uint8_t> program;
        vector<uint8_t> data;
        vector<uint8_t> expansion;
        vector<uint8_t> firmware;
    } superFamicom;
    
    uint32_t palette[0x8000];
};

Program::Program(BSNESGameCore *oeCore) : oeCore(oeCore)
{
    // tell the emulator that all event callbacks should be invoked on this object
    Emulator::platform = this;
    updateVideoPalette();
}

auto Program::save() -> void
{
    if(!emulator->loaded()) return;
    emulator->save();
}

auto Program::open(uint id, string name, vfs::file::mode mode, bool required) -> shared_pointer<vfs::file>
{
    shared_pointer<vfs::file> result;

    if ((name == "ipl.rom" || name == "boards.bml") && mode == vfs::file::mode::read) {
        NSString *nsname = [NSString stringWithUTF8String:name.begin()];
        NSURL *url = [[NSBundle bundleForClass:[oeCore class]] URLForResource:nsname withExtension:nil];
        return vfs::fs::file::open(url.fileSystemRepresentation, mode);
    }

    if (id == ::SuperFamicom::ID::SuperFamicom) { //Super Famicom
        if (name == "manifest.bml" && mode == vfs::file::mode::read) {
            result = vfs::memory::file::open(superFamicom.manifest.data<uint8_t>(), superFamicom.manifest.size());
        } else if (name == "program.rom" && mode == vfs::file::mode::read) {
            result = vfs::memory::file::open(superFamicom.program.data(), superFamicom.program.size());
        } else if (name == "data.rom" && mode == vfs::file::mode::read) {
            result = vfs::memory::file::open(superFamicom.data.data(), superFamicom.data.size());
        } else if (name == "expansion.rom" && mode == vfs::file::mode::read) {
            result = vfs::memory::file::open(superFamicom.expansion.data(), superFamicom.expansion.size());
        } else {
            result = openRomSuperFamicom(name, mode);
        }
    }
    
    if (required && !result) {
        failedLoadingAtLeastOneRequiredFile = true;
        NSLog(@"Failed loading file required by BSNES: %s", name.begin());
    }
    
    return result;
}

auto Program::load() -> void
{
    failedLoadingAtLeastOneRequiredFile = false;
    lastFailedBiosLoad.reset();
    
    emulator->unload();
    emulator->load();

    hackCompatibility();

    emulator->power();
}

auto Program::load(uint id, string name, string type, vector<string> options) -> Emulator::Platform::Load
{
    if (id == ::SuperFamicom::ID::SuperFamicom)
    {
        if (loadSuperFamicom(superFamicom.location))
        {
            return {id, superFamicom.region};
        }
    }
    return { id, options(0) };
}

auto Program::videoFrame(const uint16* data, uint pitch, uint width, uint height, uint scale) -> void
{
    BSNESGameCore *core = oeCore;
    uint32_t *outBuffer = core->videoBuffer;
    
    if (!overscan) {
        uint multiplier = height / 240;
        data += 8 * (pitch >> 1) * multiplier;
        height -= 16 * multiplier;
    }
    // avoid buffer overflows
    width = min(OE_VIDEO_BUFFER_SIZE_W, width);
    height = min(OE_VIDEO_BUFFER_SIZE_H, height);
    core->screenRect = OEIntRectMake(0, 0, width, height);
    
    uint yoffset = 0;
    for (uint y=0; y<height; y++) {
        for (uint x=0; x<width; x++) {
            uint16 color = *(data + yoffset + x);
            *(outBuffer + y*OE_VIDEO_BUFFER_SIZE_W + x) = palette[color];
        }
        yoffset += pitch / sizeof(uint16);
    }
}

// Double the fun!
static int16_t d2i16(double v)
{
    v *= 0x8000;
    if (v > 0x7fff)
        v = 0x7fff;
    else if (v < -0x8000)
        v = -0x8000;
    return int16_t(floor(v + 0.5));
}

auto Program::audioFrame(const float* samples, uint channels) -> void
{
    int16_t data[2];
    data[0] = d2i16(samples[0]);
    data[1] = d2i16(samples[1]);
    [[oeCore audioBufferAtIndex:0] write:data maxLength:sizeof(data)];
}

auto Program::inputPoll(uint port, uint device, uint input) -> int16
{
    if (device != ::SuperFamicom::ID::Device::Gamepad)
        return 0;
    BSNESGameCore *core = oeCore;
    
    /* see bsnes/sfc/interface/interface.cpp for the ordering */
    const OESNESButton buttonMap[OESNESButtonCount] = {
        OESNESButtonUp,
        OESNESButtonDown,
        OESNESButtonLeft,
        OESNESButtonRight,
        OESNESButtonB,
        OESNESButtonA,
        OESNESButtonY,
        OESNESButtonX,
        OESNESButtonTriggerLeft,
        OESNESButtonTriggerRight,
        OESNESButtonSelect,
        OESNESButtonStart};
        
    return core->pad[port][buttonMap[input]];
}

auto Program::inputRumble(uint port, uint device, uint input, bool enable) -> void
{
}

auto Program::openRomSuperFamicom(string name, vfs::file::mode mode) -> shared_pointer<vfs::file>
{
    if(name == "program.rom" && mode == vfs::file::mode::read) {
        return vfs::memory::file::open(superFamicom.program.data(), superFamicom.program.size());
    }
    
    if(name == "data.rom" && mode == vfs::file::mode::read) {
        return vfs::memory::file::open(superFamicom.data.data(), superFamicom.data.size());
    }
    
    if(name == "expansion.rom" && mode == vfs::file::mode::read) {
        return vfs::memory::file::open(superFamicom.expansion.data(), superFamicom.expansion.size());
    }
    
    /* DSP3.rom */
    if ((name == "upd7725.program.rom" || name == "upd7725.data.rom") && !superFamicom.firmware.size()) {
        if(auto memory = superFamicom.document["game/board/memory(type=ROM,content=Program,architecture=uPD7725)"]) {
            loadSuperFamicomFirmware(memory["identifier"].text().downcase());
        }
    }
    if(name == "upd7725.program.rom" && mode == vfs::file::mode::read) {
      if(superFamicom.firmware.size() == 0x2000) {
        return vfs::memory::file::open(&superFamicom.firmware.data()[0x0000], 0x1800);
      }
    }
    if(name == "upd7725.data.rom" && mode == vfs::file::mode::read) {
      if(superFamicom.firmware.size() == 0x2000) {
        return vfs::memory::file::open(&superFamicom.firmware.data()[0x1800], 0x0800);
      }
    }
    
    /* ST018.rom */
    if ((name == "arm6.program.rom" || name == "arm6.data.rom") && !superFamicom.firmware.size()) {
        if(auto memory = superFamicom.document["game/board/memory(type=ROM,content=Program,architecture=ARM6)"]) {
            loadSuperFamicomFirmware(memory["identifier"].text().downcase());
        }
    }
    if(name == "arm6.program.rom" && mode == vfs::file::mode::read) {
        if(superFamicom.firmware.size() == 0x28000) {
            return vfs::memory::file::open(&superFamicom.firmware.data()[0x00000], 0x20000);
        }
    }
    if(name == "arm6.data.rom" && mode == vfs::file::mode::read) {
        if(superFamicom.firmware.size() == 0x28000) {
            return vfs::memory::file::open(&superFamicom.firmware.data()[0x20000], 0x08000);
        }
    }
    
    /* ST011.rom */
    if ((name == "upd96050.program.rom" || name == "upd96050.data.rom") && !superFamicom.firmware.size()) {
        if(auto memory = superFamicom.document["game/board/memory(type=ROM,content=Program,architecture=uPD96050)"]) {
            loadSuperFamicomFirmware(memory["identifier"].text().downcase());
        }
    }
    if(name == "upd96050.program.rom" && mode == vfs::file::mode::read) {
      if(superFamicom.firmware.size() == 0xd000) {
        return vfs::memory::file::open(&superFamicom.firmware.data()[0x0000], 0xc000);
      }
    }
    if(name == "upd96050.data.rom" && mode == vfs::file::mode::read) {
      if(superFamicom.firmware.size() == 0xd000) {
        return vfs::memory::file::open(&superFamicom.firmware.data()[0xc000], 0x1000);
      }
    }
    
    if(name == "save.ram") {
        NSURL *gameFn = [NSURL fileURLWithFileSystemRepresentation:base_name.begin() isDirectory:NO relativeToURL:nil];
        NSString *gameBasename = [gameFn lastPathComponent];
        NSString *gameBasenameNoExt = [gameBasename stringByDeletingPathExtension];
        NSURL *batterySavesDir = [NSURL fileURLWithPath:oeCore.batterySavesDirectoryPath];
        NSURL *savePath = [batterySavesDir URLByAppendingPathComponent:[gameBasenameNoExt stringByAppendingPathExtension:@"srm"]];
        
        if (!nall::file::exists(savePath.fileSystemRepresentation)) {
            /* attempt importing an old save file from the Higan core */
            NSURL *higanBattSaveDir = [NSURL fileURLWithPath:@"../../Higan/Super Famicom/" relativeToURL:batterySavesDir];
            NSURL *higanBundleDir = [higanBattSaveDir URLByAppendingPathComponent:gameBasename isDirectory:YES];
            NSURL *higanSavePath = [higanBundleDir URLByAppendingPathComponent:@"save.ram"];
            if (nall::file::copy(higanSavePath.fileSystemRepresentation, savePath.fileSystemRepresentation)) {
                NSLog(@"Imported Higan save.ram file %@", higanSavePath.path);
            } else {
                NSLog(@"No existing save.ram file found");
            }
        } else {
            NSLog(@"Opening save.ram file %@", savePath.path);
        }
        
        return vfs::fs::file::open(savePath.fileSystemRepresentation, mode);
    }

    return {};
}

auto Program::loadSuperFamicomFirmware(string fwname) -> void
{
    string biosfn = string(fwname).append(".rom");
    string path = oeCore.biosDirectoryPath.fileSystemRepresentation;
    path.append("/", biosfn);
    NSLog(@"Attempting to load BIOS file %s", path.begin());
    superFamicom.firmware = file::read(path);
    if (superFamicom.firmware.size() == 0)
        lastFailedBiosLoad = biosfn;
}

auto Program::loadFile(string location) -> vector<uint8_t>
{
    return file::read(location);
}

auto Program::loadSuperFamicom(string location) -> bool
{
    string manifest;
    vector<uint8_t> rom;
    rom = loadFile(location);

    if(rom.size() < 0x8000) return false;

    //assume ROM and IPS agree on whether a copier header is present
    //superFamicom.patched = applyPatchIPS(rom, location);
    if((rom.size() & 0x7fff) == 512) {
        //remove copier header
        memory::move(&rom[0], &rom[512], (uint)(rom.size() - 512));
        rom.resize(rom.size() - 512);
    }

    auto heuristics = Heuristics::SuperFamicom(rom, location);
    auto sha256 = Hash::SHA256(rom).digest();
    superFamicom.title = heuristics.title();
    superFamicom.region = heuristics.videoRegion();
    NSURL *dburl = [[NSBundle bundleForClass:[oeCore class]] URLForResource:@"Super Famicom" withExtension:@"bml"];
    if(auto document = BML::unserialize(string::read(dburl.fileSystemRepresentation))) {
      if(auto game = document[{"game(sha256=", sha256, ")"}]) {
        manifest = BML::serialize(game);
        //the internal ROM header title is not present in the database, but is needed for internal core overrides
        manifest.append("  title: ", superFamicom.title, "\n");
        superFamicom.verified = true;
        NSLog(@"The game being loaded (sha256=%s, title=%s) is VERIFIED", sha256.begin(), superFamicom.title.begin());
      } else {
        NSLog(@"The game being loaded (sha256=%s, title=%s) is NOT VERIFIED", sha256.begin(), superFamicom.title.begin());
      }
    }
    superFamicom.manifest = manifest ? manifest : heuristics.manifest();
    hackPatchMemory(rom);
    superFamicom.document = BML::unserialize(superFamicom.manifest);
    superFamicom.location = location;
    
    NSLog(@"Region of game: %s", superFamicom.region.begin());

    uint offset = 0;
    if(auto size = heuristics.programRomSize()) {
        superFamicom.program.resize(size);
        memory::copy(&superFamicom.program[0], &rom[offset], size);
        offset += size;
    }
    if(auto size = heuristics.dataRomSize()) {
        superFamicom.data.resize(size);
        memory::copy(&superFamicom.data[0], &rom[offset], size);
        offset += size;
    }
    if(auto size = heuristics.expansionRomSize()) {
        superFamicom.expansion.resize(size);
        memory::copy(&superFamicom.expansion[0], &rom[offset], size);
        offset += size;
    }
    if(auto size = heuristics.firmwareRomSize()) {
        superFamicom.firmware.resize(size);
        memory::copy(&superFamicom.firmware[0], &rom[offset], size);
        offset += size;
    }
    return true;
}

// Keep in sync with bsnes/target-bsnes/program/hacks.cpp
auto Program::hackCompatibility() -> void
{
    string entropy = ::SuperFamicom::configuration.hacks.entropy;
    bool fastJoypadPolling = false;
    bool fastPPU = ::SuperFamicom::configuration.hacks.ppu.fast;
    bool fastPPUNoSpriteLimit = ::SuperFamicom::configuration.hacks.ppu.noSpriteLimit;
    bool fastDSP = ::SuperFamicom::configuration.hacks.dsp.fast;
    bool coprocessorDelayedSync = ::SuperFamicom::configuration.hacks.coprocessor.delayedSync;
    uint renderCycle = 512;
    
    auto title = superFamicom.title;
    auto region = superFamicom.region;
    
    //sometimes menu options are skipped over in the main menu with cycle-based joypad polling
    if(title == "Arcades Greatest Hits") fastJoypadPolling = true;
    
    //the start button doesn't work in this game with cycle-based joypad polling
    if(title == "TAIKYOKU-IGO Goliath") fastJoypadPolling = true;
    
    //holding up or down on the menu quickly cycles through options instead of stopping after each button press
    if(title == "WORLD MASTERS GOLF") fastJoypadPolling = true;
    
    //relies on mid-scanline rendering techniques
    if(title == "AIR STRIKE PATROL" || title == "DESERT FIGHTER") fastPPU = false;
    
    //the dialogue text is blurry due to an issue in the scanline-based renderer's color math support
    if(title == "マーヴェラス") fastPPU = false;
    
    //stage 2 uses pseudo-hires in a way that's not compatible with the scanline-based renderer
    if(title == "SFC クレヨンシンチャン") fastPPU = false;
    
    //title screen game select (after choosing a game) changes OAM tiledata address mid-frame
    //this is only supported by the cycle-based PPU renderer
    if(title == "Winter olympics") fastPPU = false;
    
    //title screen shows remnants of the flag after choosing a language with the scanline-based renderer
    if(title == "WORLD CUP STRIKER") fastPPU = false;
    
    //relies on cycle-accurate writes to the echo buffer
    if(title == "KOUSHIEN_2") fastDSP = false;
    
    //will hang immediately
    if(title == "RENDERING RANGER R2") fastDSP = false;
    
    //will hang sometimes in the "Bach in Time" stage
    if(title == "BUBSY II" && region == "PAL") fastDSP = false;
    
    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "ADVENTURES OF FRANKEN" && region == "PAL") renderCycle = 32;
    
    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "FIREPOWER 2000" || title == "SUPER SWIV") renderCycle = 32;
    
    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "NHL '94" || title == "NHL PROHOCKEY'94") renderCycle = 32;
    
    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "Sugoro Quest++") renderCycle = 128;
    
    if(::SuperFamicom::configuration.hacks.hotfixes) {
        //this game transfers uninitialized memory into video RAM: this can cause a row of invalid tiles
        //to appear in the background of stage 12. this one is a bug in the original game, so only enable
        //it if the hotfixes option has been enabled.
        if(title == "The Hurricanes") entropy = "None";
        
        //Frisky Tom attract sequence sometimes hangs when WRAM is initialized to pseudo-random patterns
        if(title == "ニチブツ・アーケード・クラシックス") entropy = "None";
    }
    
    emulator->configure("Hacks/Entropy", entropy);
    emulator->configure("Hacks/CPU/FastJoypadPolling", fastJoypadPolling);
    emulator->configure("Hacks/PPU/Fast", fastPPU);
    emulator->configure("Hacks/PPU/NoSpriteLimit", fastPPUNoSpriteLimit);
    emulator->configure("Hacks/PPU/RenderCycle", renderCycle);
    emulator->configure("Hacks/DSP/Fast", fastDSP);
    emulator->configure("Hacks/Coprocessor/DelayedSync", coprocessorDelayedSync);
}

// Keep in sync with bsnes/target-bsnes/program/hacks.cpp
auto Program::hackPatchMemory(vector<uint8_t>& data) -> void
{
    auto title = superFamicom.title;

    if(title == "Satellaview BS-X" && data.size() >= 0x100000) {
        //BS-X: Sore wa Namae o Nusumareta Machi no Monogatari (JPN) (1.1)
        //disable limited play check for BS Memory flash cartridges
        //benefit: allow locked out BS Memory flash games to play without manual header patching
        //detriment: BS Memory ROM cartridges will cause the game to hang in the load menu
        if(data[0x4a9b] == 0x10) data[0x4a9b] = 0x80;
        if(data[0x4d6d] == 0x10) data[0x4d6d] = 0x80;
        if(data[0x4ded] == 0x10) data[0x4ded] = 0x80;
        if(data[0x4e9a] == 0x10) data[0x4e9a] = 0x80;
    }
}

auto Program::updateVideoPalette() -> void
{
    static const uint8 gammaRamp_colorEmulation[32] = {
      0x00, 0x01, 0x03, 0x06, 0x0a, 0x0f, 0x15, 0x1c,
      0x24, 0x2d, 0x37, 0x42, 0x4e, 0x5b, 0x69, 0x78,
      0x88, 0x90, 0x98, 0xa0, 0xa8, 0xb0, 0xb8, 0xc0,
      0xc8, 0xd0, 0xd8, 0xe0, 0xe8, 0xf0, 0xf8, 0xff,
    };
    static const uint8 gammaRamp_linear[32] = {
      0x00, 0x08, 0x10, 0x18, 0x21, 0x29, 0x31, 0x39,
      0x42, 0x4a, 0x52, 0x5a, 0x63, 0x6b, 0x73, 0x7b,
      0x84, 0x8c, 0x94, 0x9c, 0xa5, 0xad, 0xb5, 0xbd,
      0xc6, 0xce, 0xd6, 0xde, 0xe7, 0xef, 0xf7, 0xff,
    };
    const uint8 *gammaRamp = gammaRamp_linear;
    if (::SuperFamicom::configuration.video.colorEmulation)
        gammaRamp = gammaRamp_colorEmulation;
    
    for (uint16_t color = 0; color < 0x8000; color++) {
        uint16 r = (color >>  0) & 31;
        uint16 g = (color >>  5) & 31;
        uint16 b = (color >> 10) & 31;
        palette[color] =
             ((uint32_t)gammaRamp[r])       +
            (((uint32_t)gammaRamp[g]) << 8) +
            (((uint32_t)gammaRamp[b]) << 16);
    }
}


#pragma mark - Utility Functions


// The following function is copy-pasted from
// bsnes/target-bsnes/cheat-editor.cpp
// (its original name was CheatEditor::decodeSNES)

auto OEBSNESCheatDecodeSNES(string& code) -> bool
{
  //Game Genie
  if(code.size() == 9 && code[4] == '-') {
    //strip '-'
    code = {code.slice(0, 4), code.slice(5, 4)};
    //validate
    for(uint n : code) {
      if(n >= '0' && n <= '9') continue;
      if(n >= 'a' && n <= 'f') continue;
      return false;
    }
    //decode
    code.transform("df4709156bc8a23e", "0123456789abcdef");
    uint32_t r = toHex(code);
    //abcd efgh ijkl mnop qrst uvwx
    //ijkl qrst opab cduv wxef ghmn
    uint address =
      (!!(r & 0x002000) << 23) | (!!(r & 0x001000) << 22)
    | (!!(r & 0x000800) << 21) | (!!(r & 0x000400) << 20)
    | (!!(r & 0x000020) << 19) | (!!(r & 0x000010) << 18)
    | (!!(r & 0x000008) << 17) | (!!(r & 0x000004) << 16)
    | (!!(r & 0x800000) << 15) | (!!(r & 0x400000) << 14)
    | (!!(r & 0x200000) << 13) | (!!(r & 0x100000) << 12)
    | (!!(r & 0x000002) << 11) | (!!(r & 0x000001) << 10)
    | (!!(r & 0x008000) <<  9) | (!!(r & 0x004000) <<  8)
    | (!!(r & 0x080000) <<  7) | (!!(r & 0x040000) <<  6)
    | (!!(r & 0x020000) <<  5) | (!!(r & 0x010000) <<  4)
    | (!!(r & 0x000200) <<  3) | (!!(r & 0x000100) <<  2)
    | (!!(r & 0x000080) <<  1) | (!!(r & 0x000040) <<  0);
    uint data = r >> 24;
    code = {hex(address, 6L), "=", hex(data, 2L)};
    return true;
  }

  //Pro Action Replay
  if(code.size() == 8) {
    //validate
    for(uint n : code) {
      if(n >= '0' && n <= '9') continue;
      if(n >= 'a' && n <= 'f') continue;
      return false;
    }
    //decode
    uint32_t r = toHex(code);
    uint address = r >> 8;
    uint data = r & 0xff;
    code = {hex(address, 6L), "=", hex(data, 2L)};
    return true;
  }

  //higan: address=data
  if(code.size() == 9 && code[6] == '=') {
    string nibbles = {code.slice(0, 6), code.slice(7, 2)};
    //validate
    for(uint n : nibbles) {
      if(n >= '0' && n <= '9') continue;
      if(n >= 'a' && n <= 'f') continue;
      return false;
    }
    //already in decoded form
    return true;
  }

  //higan: address=compare?data
  if(code.size() == 12 && code[6] == '=' && code[9] == '?') {
    string nibbles = {code.slice(0, 6), code.slice(7, 2), code.slice(10, 2)};
    //validate
    for(uint n : nibbles) {
      if(n >= '0' && n <= '9') continue;
      if(n >= 'a' && n <= 'f') continue;
      return false;
    }
    //already in decoded form
    return true;
  }

  //unrecognized code format
  return false;
}
