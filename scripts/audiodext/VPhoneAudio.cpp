// VPhoneAudio.cpp — virtual stereo OUTPUT device (null sink for now).
// Structured after Apple's SimpleAudioDriver sample: all device setup in
// VPhoneAudioDevice::init; StartIO maps the stream ring + starts the ZTS timer.
#include <AudioDriverKit/AudioDriverKit.h>
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSSharedPtr.h>

#include <VPhoneAudio/VPhoneAudioDevice.h>
#include <VPhoneAudio/VPhoneAudio.h>

#define kVPhoneDeviceUID    "VPhoneAudioDevice"
#define kVPhoneModelUID     "VPhoneAudioModel"
#define kVPhoneManufacturer "VPhone"
#define kVPhoneDeviceName   "VPhone Virtual Output"

static const double   kSampleRate     = 48000.0;
static const uint32_t kChannels       = 2;
static const uint32_t kBitsPerChannel = 32;
static const uint32_t kBytesPerFrame  = (kBitsPerChannel / 8) * kChannels;   // 8
static const uint32_t kZeroTSPeriod   = 32768;   // matches Apple sample

// =====================================================================
// VPhoneAudioDevice
// =====================================================================
struct VPhoneAudioDevice_IVars
{
    OSSharedPtr<IOUserAudioDriver>       m_driver;
    OSSharedPtr<IODispatchQueue>         m_work_queue;
    uint64_t                             m_zts_host_ticks_per_buffer;
    IOUserAudioStreamBasicDescription    m_stream_format;
    OSSharedPtr<IOUserAudioStream>       m_output_stream;
    OSSharedPtr<IOMemoryMap>             m_output_memory_map;
    OSSharedPtr<IOTimerDispatchSource>   m_zts_timer;
    OSSharedPtr<OSAction>                m_zts_action;
};

bool
VPhoneAudioDevice::init(IOUserAudioDriver* in_driver,
                        bool in_supports_prewarming,
                        OSString* in_device_uid,
                        OSString* in_model_uid,
                        OSString* in_manufacturer_uid,
                        uint32_t in_zero_timestamp_period)
{
    if (!super::init(in_driver, in_supports_prewarming, in_device_uid,
                     in_model_uid, in_manufacturer_uid, in_zero_timestamp_period)) {
        return false;
    }
    ivars = IONewZero(VPhoneAudioDevice_IVars, 1);
    if (ivars == nullptr) { return false; }

    ivars->m_driver     = OSSharedPtr(in_driver, OSRetain);
    ivars->m_work_queue = GetWorkQueue();

    // Device-level sample rate set (required for a valid device).
    double rates[] = { kSampleRate };
    SetAvailableSampleRates(rates, 1);
    SetSampleRate(kSampleRate);

    // Ensure the device is visible to all HAL clients (not hidden/private).
    SetIsHidden(false);

    IOUserAudioStreamBasicDescription fmt = {
        kSampleRate, IOUserAudioFormatID::LinearPCM,
        static_cast<IOUserAudioFormatFlags>(IOUserAudioFormatFlags::FormatFlagIsFloat |
                                            IOUserAudioFormatFlags::FormatFlagsNativeEndian |
                                            IOUserAudioFormatFlags::FormatFlagIsPacked),
        kBytesPerFrame, 1, kBytesPerFrame, kChannels, kBitsPerChannel, 0
    };

    const uint32_t buffer_size_bytes = in_zero_timestamp_period * kBytesPerFrame;
    OSSharedPtr<IOBufferMemoryDescriptor> ring;
    if (IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, buffer_size_bytes, 0, ring.attach()) != kIOReturnSuccess) {
        return false;
    }

    ivars->m_output_stream = IOUserAudioStream::Create(in_driver, IOUserAudioStreamDirection::Output, ring.get());
    if (ivars->m_output_stream.get() == nullptr) { return false; }

    auto sname = OSSharedPtr(OSString::withCString("VPhoneOutputStream"), OSNoRetain);
    ivars->m_output_stream->SetName(sname.get());
    ivars->m_output_stream->SetAvailableStreamFormats(&fmt, 1);
    ivars->m_stream_format = fmt;
    ivars->m_output_stream->SetCurrentStreamFormat(&fmt);

    if (AddStream(ivars->m_output_stream.get()) != kIOReturnSuccess) { return false; }

    SetTransportType(IOUserAudioTransportType::BuiltIn);

    // ZTS timer (drives the zero-timestamp clock while IO is running).
    IOTimerDispatchSource* tds = nullptr;
    if (IOTimerDispatchSource::Create(ivars->m_work_queue.get(), &tds) != kIOReturnSuccess) { return false; }
    ivars->m_zts_timer = OSSharedPtr(tds, OSNoRetain);

    OSAction* act = nullptr;
    if (CreateActionZtsTimerOccurred(sizeof(void*), &act) != kIOReturnSuccess) { return false; }
    ivars->m_zts_action = OSSharedPtr(act, OSNoRetain);
    ivars->m_zts_timer->SetHandler(ivars->m_zts_action.get());

    // Real-time IO callback: null sink (discard host-written output).
    IOOperationHandler io = ^kern_return_t(IOUserAudioObjectID,
                                           IOUserAudioIOOperation in_op,
                                           uint32_t, uint64_t, uint64_t) {
        (void)in_op;   // IOUserAudioIOOperationWriteEnd: host wrote output -> discard
        return kIOReturnSuccess;
    };
    SetIOOperationHandler(io);

    return true;
}

void
VPhoneAudioDevice::free()
{
    if (ivars != nullptr) {
        ivars->m_driver.reset();
        ivars->m_output_stream.reset();
        ivars->m_output_memory_map.reset();
        ivars->m_zts_timer.reset();
        ivars->m_zts_action.reset();
        ivars->m_work_queue.reset();
    }
    IOSafeDeleteNULL(ivars, VPhoneAudioDevice_IVars, 1);
    super::free();
}

kern_return_t
VPhoneAudioDevice::StartIO(IOUserAudioStartStopFlags in_flags)
{
    __block kern_return_t error = kIOReturnSuccess;
    ivars->m_work_queue->DispatchSync(^(){
        error = super::StartIO(in_flags);
        if (error != kIOReturnSuccess) { return; }

        auto iomd = ivars->m_output_stream->GetIOMemoryDescriptor();
        if (iomd.get() == nullptr) { error = kIOReturnNoMemory; super::StopIO(in_flags); return; }
        error = iomd->CreateMapping(0, 0, 0, 0, 0, ivars->m_output_memory_map.attach());
        if (error != kIOReturnSuccess) { super::StopIO(in_flags); return; }

        StartTimers();
    });
    return error;
}

kern_return_t
VPhoneAudioDevice::StopIO(IOUserAudioStartStopFlags in_flags)
{
    __block kern_return_t error = kIOReturnSuccess;
    ivars->m_work_queue->DispatchSync(^(){
        StopTimers();
        ivars->m_output_memory_map.reset();
        error = super::StopIO(in_flags);
    });
    return error;
}

void
VPhoneAudioDevice::UpdateTimers()
{
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    double sample_rate = ivars->m_stream_format.mSampleRate;
    double host_ticks = (double)GetZeroTimestampPeriod() * (double)NSEC_PER_SEC / sample_rate;
    host_ticks = host_ticks * (double)tb.denom / (double)tb.numer;
    ivars->m_zts_host_ticks_per_buffer = (uint64_t)host_ticks;
}

kern_return_t
VPhoneAudioDevice::StartTimers()
{
    UpdateTimers();
    if (ivars->m_zts_timer.get() == nullptr) { return kIOReturnNoResources; }
    UpdateCurrentZeroTimestamp(0, 0);
    uint64_t now = mach_absolute_time();
    ivars->m_zts_timer->WakeAtTime(kIOTimerClockMachAbsoluteTime,
                                   now + ivars->m_zts_host_ticks_per_buffer, 0);
    ivars->m_zts_timer->SetEnable(true);
    return kIOReturnSuccess;
}

void
VPhoneAudioDevice::StopTimers()
{
    if (ivars->m_zts_timer.get() != nullptr) {
        ivars->m_zts_timer->SetEnable(false);
    }
}

void
IMPL(VPhoneAudioDevice, ZtsTimerOccurred)
{
    uint64_t cur_sample = 0, cur_host = 0;
    GetCurrentZeroTimestamp(&cur_sample, &cur_host);
    uint64_t ticks = ivars->m_zts_host_ticks_per_buffer;

    if (cur_host != 0) {
        cur_sample += GetZeroTimestampPeriod();
        cur_host   += ticks;
    } else {
        cur_sample = 0;
        cur_host   = time;
    }
    UpdateCurrentZeroTimestamp(cur_sample, cur_host);
    ivars->m_zts_timer->WakeAtTime(kIOTimerClockMachAbsoluteTime, cur_host + ticks, 0);
}

// =====================================================================
// VPhoneAudio (driver)
// =====================================================================
struct VPhoneAudio_IVars
{
    OSSharedPtr<IODispatchQueue>      m_work_queue;
    OSSharedPtr<VPhoneAudioDevice>    m_device;
};

bool
VPhoneAudio::init()
{
    if (!super::init()) { return false; }
    ivars = IONewZero(VPhoneAudio_IVars, 1);
    if (ivars == nullptr) { return false; }
    return true;
}

void
VPhoneAudio::free()
{
    if (ivars != nullptr) {
        ivars->m_work_queue.reset();
        ivars->m_device.reset();
    }
    IOSafeDeleteNULL(ivars, VPhoneAudio_IVars, 1);
    super::free();
}

kern_return_t
IMPL(VPhoneAudio, Start)
{
    kern_return_t error = Start(provider, SUPERDISPATCH);
    if (error != kIOReturnSuccess) { IOService::SetName("VPDiag_super_fail"); return error; }

    ivars->m_work_queue = GetWorkQueue();
    if (ivars->m_work_queue.get() == nullptr) { IOService::SetName("VPDiag_no_wq"); return kIOReturnInvalid; }

    auto uid  = OSSharedPtr(OSString::withCString(kVPhoneDeviceUID),    OSNoRetain);
    auto mod  = OSSharedPtr(OSString::withCString(kVPhoneModelUID),     OSNoRetain);
    auto man  = OSSharedPtr(OSString::withCString(kVPhoneManufacturer), OSNoRetain);
    auto name = OSSharedPtr(OSString::withCString(kVPhoneDeviceName),   OSNoRetain);

    ivars->m_device = OSSharedPtr(OSTypeAlloc(VPhoneAudioDevice), OSNoRetain);
    if (ivars->m_device.get() == nullptr) { IOService::SetName("VPDiag_alloc_fail"); return kIOReturnNoMemory; }

    if (!ivars->m_device->init(this, false, uid.get(), mod.get(), man.get(), kZeroTSPeriod)) {
        IOService::SetName("VPDiag_dev_init_fail");
        return kIOReturnNoMemory;
    }
    ivars->m_device->SetName(name.get());
    ivars->m_device->SetCanBeDefaultOutputDevice(true);
    ivars->m_device->SetCanBeDefaultSystemOutputDevice(true);

    AddObject(ivars->m_device.get());

    error = RegisterService();
    if (error != kIOReturnSuccess) { IOService::SetName("VPDiag_register_fail"); return error; }

    IOService::SetName("VPDiag_all_ok");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(VPhoneAudio, Stop)
{
    if (ivars != nullptr && ivars->m_device.get() != nullptr) {
        RemoveObject(ivars->m_device.get());
    }
    kern_return_t ret = Stop(provider, SUPERDISPATCH);
    if (ivars != nullptr) {
        ivars->m_work_queue.reset();
        ivars->m_device.reset();
    }
    return ret;
}
