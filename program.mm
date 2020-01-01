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
    
    auto hackPatchMemory(vector<uint8_t>& data) -> void;
    
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
};

/* The actual SFC emulator object. Communicates to the front-end (an instance
 * of Emulator::Platform) through the Emulator::platform global variable.
 * Owned by BSNESGameCore */
static Emulator::Interface *emulator;

/* The current instance of Emulator::Platform
 * Owned by BSNESGameCore */
static Program *program = nullptr;

Program::Program(BSNESGameCore *oeCore) : oeCore(oeCore)
{
    // tell the emulator that all event callbacks should be invoked on this object
    Emulator::platform = this;
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

    // per-game hack overrides
    auto title = superFamicom.title;
    auto region = superFamicom.region;

    //relies on mid-scanline rendering techniques
    if(title == "AIR STRIKE PATROL" || title == "DESERT FIGHTER") emulator->configure("Hacks/PPU/Fast", false);

    //stage 2 uses pseudo-hires in a way that's not compatible with the scanline-based renderer
    if(title == "SFC クレヨンシンチャン") emulator->configure("Hacks/PPU/Fast", false);

    //relies on cycle-accurate writes to the echo buffer
    if(title == "KOUSHIEN_2") emulator->configure("Hacks/DSP/Fast", false);

    //will hang immediately
    if(title == "RENDERING RANGER R2") emulator->configure("Hacks/DSP/Fast", false);

    //will hang sometimes in the "Bach in Time" stage
    if(title == "BUBSY II" && region == "PAL") emulator->configure("Hacks/DSP/Fast", false);

    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "ADVENTURES OF FRANKEN" && region == "PAL") emulator->configure("Hacks/PPU/RenderCycle", 32);

    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "FIREPOWER 2000") emulator->configure("Hacks/PPU/RenderCycle", 32);

    //fixes an errant scanline on the title screen due to writing to PPU registers too late
    if(title == "NHL '94" || title == "NHL PROHOCKEY'94") emulator->configure("Hacks/PPU/RenderCycle", 32);

    if (emulator->configuration("Hacks/Hotfixes")) {
        if (title == "The Hurricanes") emulator->configure("Hacks/Entropy", "None");
    }

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
    core->screenRect = OEIntRectMake(0, 0, width, height);
    
    uint yoffset = 0;
    for (uint y=0; y<height; y++) {
        for (uint x=0; x<width; x++) {
            uint32 color = *(data + yoffset + x) | (0xF << 15);
            uint64 realcolor = emulator->color(color);
            uint8 r, g, b;
            b = (realcolor >> 8) & 0xFF;
            g = (realcolor >> 24) & 0xFF;
            r = (realcolor >> 40) & 0xFF;
            *(outBuffer + y*512 + x) = r + g * 0x100 + b * 0x10000;
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
        string save_path;
        
        auto suffix = Location::suffix(base_name);
        auto base = Location::base(base_name.transform("\\", "/"));
        
        const char *save = oeCore.batterySavesDirectoryPath.fileSystemRepresentation;
        if (save)
            save_path = { string(save).transform("\\", "/"), "/", base.trimRight(suffix, 1L), ".srm" };
        else
            save_path = { base_name.trimRight(suffix, 1L), ".srm" };
        
        return vfs::fs::file::open(save_path, mode);
    }

    return {};
}

auto Program::loadSuperFamicomFirmware(string fwname) -> void
{
    string biosfn = string(fwname).append(".rom");
    string path = oeCore.biosDirectoryPath.fileSystemRepresentation;
    path.append("/", biosfn);
    NSLog(@"attempting to load BIOS file %s", path.begin());
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
