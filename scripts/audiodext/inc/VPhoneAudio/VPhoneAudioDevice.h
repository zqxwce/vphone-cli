/* iig(DriverKit-440) generated from VPhoneAudioDevice.iig */

/* VPhoneAudioDevice.iig:1-14 */
// VPhoneAudioDevice.iig — IOUserAudioDevice subclass (output-only, null sink)
#ifndef VPhoneAudioDevice_h
#define VPhoneAudioDevice_h

#include <DriverKit/DriverKit.h>  /* .iig include */
#include <AudioDriverKit/IOUserAudioDevice.h>  /* .iig include */
#include <AudioDriverKit/IOUserAudioStream.h>  /* .iig include */
#include <AudioDriverKit/AudioDriverKitTypes.h>
#include <DriverKit/IOTimerDispatchSource.h>  /* .iig include */

using namespace AudioDriverKit;

class IOUserAudioDriver;

/* source class VPhoneAudioDevice VPhoneAudioDevice.iig:15-33 */

#if __DOCUMENTATION__
#define KERNEL IIG_KERNEL

class VPhoneAudioDevice: public IOUserAudioDevice
{
public:
    virtual bool          init(IOUserAudioDriver* in_driver,
                               bool in_supports_prewarming,
                               OSString* in_device_uid,
                               OSString* in_model_uid,
                               OSString* in_manufacturer_uid,
                               uint32_t in_zero_timestamp_period) override LOCALONLY;
    virtual void          free() override LOCALONLY;
    virtual kern_return_t StartIO(IOUserAudioStartStopFlags in_flags) final LOCALONLY;
    virtual kern_return_t StopIO(IOUserAudioStartStopFlags in_flags) final LOCALONLY;

private:
    kern_return_t StartTimers() LOCALONLY;
    void          StopTimers() LOCALONLY;
    void          UpdateTimers() LOCALONLY;
    virtual void  ZtsTimerOccurred(OSAction* action, uint64_t time)
                      TYPE(IOTimerDispatchSource::TimerOccurred);
};

#undef KERNEL
#else /* __DOCUMENTATION__ */

/* generated class VPhoneAudioDevice VPhoneAudioDevice.iig:15-33 */

#define VPhoneAudioDevice_ZtsTimerOccurred_ID            0x51f7758ae952b4feULL

#define VPhoneAudioDevice_ZtsTimerOccurred_Args \
        OSAction * action, \
        uint64_t time

#define VPhoneAudioDevice_Methods \
\
public:\
\
    virtual kern_return_t\
    Dispatch(const IORPC rpc) APPLE_KEXT_OVERRIDE;\
\
    static kern_return_t\
    _Dispatch(VPhoneAudioDevice * self, const IORPC rpc);\
\
    kern_return_t\
    StartTimers(\
);\
\
    void\
    StopTimers(\
);\
\
    void\
    UpdateTimers(\
);\
\
    kern_return_t\
    CreateActionZtsTimerOccurred(size_t referenceSize, OSAction ** action);\
\
\
protected:\
    /* _Impl methods */\
\
    void\
    ZtsTimerOccurred_Impl(VPhoneAudioDevice_ZtsTimerOccurred_Args);\
\
\
public:\
    /* _Invoke methods */\
\


#define VPhoneAudioDevice_KernelMethods \
\
protected:\
    /* _Impl methods */\
\


#define VPhoneAudioDevice_VirtualMethods \
\
public:\
\
    virtual bool\
    init(\
        IOUserAudioDriver * in_driver,\
        bool in_supports_prewarming,\
        OSString * in_device_uid,\
        OSString * in_model_uid,\
        OSString * in_manufacturer_uid,\
        uint32_t in_zero_timestamp_period) APPLE_KEXT_OVERRIDE;\
\
    virtual void\
    free(\
) APPLE_KEXT_OVERRIDE;\
\
    virtual kern_return_t\
    StartIO(\
        IOUserAudioStartStopFlags in_flags) APPLE_KEXT_OVERRIDE;\
\
    virtual kern_return_t\
    StopIO(\
        IOUserAudioStartStopFlags in_flags) APPLE_KEXT_OVERRIDE;\
\


#if !KERNEL

extern OSMetaClass          * gVPhoneAudioDeviceMetaClass;
extern const OSClassLoadInformation VPhoneAudioDevice_Class;

class VPhoneAudioDeviceMetaClass : public OSMetaClass
{
public:
    virtual kern_return_t
    New(OSObject * instance) override;
    virtual kern_return_t
    Dispatch(const IORPC rpc) override;
};

#endif /* !KERNEL */

#if !KERNEL

class  VPhoneAudioDeviceInterface : public OSInterface
{
public:
};

struct VPhoneAudioDevice_IVars;
struct VPhoneAudioDevice_LocalIVars;

class VPhoneAudioDevice : public IOUserAudioDevice, public VPhoneAudioDeviceInterface
{
#if !KERNEL
    friend class VPhoneAudioDeviceMetaClass;
#endif /* !KERNEL */

#if !KERNEL
public:
#ifdef VPhoneAudioDevice_DECLARE_IVARS
VPhoneAudioDevice_DECLARE_IVARS
#else /* VPhoneAudioDevice_DECLARE_IVARS */
    union
    {
        VPhoneAudioDevice_IVars * ivars;
        VPhoneAudioDevice_LocalIVars * lvars;
    };
#endif /* VPhoneAudioDevice_DECLARE_IVARS */
#endif /* !KERNEL */

#if !KERNEL
    static OSMetaClass *
    sGetMetaClass() { return gVPhoneAudioDeviceMetaClass; };
#endif /* KERNEL */

    using super = IOUserAudioDevice;

#if !KERNEL
    VPhoneAudioDevice_Methods
    VPhoneAudioDevice_VirtualMethods
#endif /* !KERNEL */

};
#endif /* !KERNEL */


#define OSAction_VPhoneAudioDevice_ZtsTimerOccurred_Methods \
\
public:\
\
    virtual kern_return_t\
    Dispatch(const IORPC rpc) APPLE_KEXT_OVERRIDE;\
\
    static kern_return_t\
    _Dispatch(OSAction_VPhoneAudioDevice_ZtsTimerOccurred * self, const IORPC rpc);\
\
\
protected:\
    /* _Impl methods */\
\
\
public:\
    /* _Invoke methods */\
\


#define OSAction_VPhoneAudioDevice_ZtsTimerOccurred_KernelMethods \
\
protected:\
    /* _Impl methods */\
\


#define OSAction_VPhoneAudioDevice_ZtsTimerOccurred_VirtualMethods \
\
public:\
\


#if !KERNEL

extern OSMetaClass          * gOSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass;
extern const OSClassLoadInformation OSAction_VPhoneAudioDevice_ZtsTimerOccurred_Class;

class OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass : public OSMetaClass
{
public:
    virtual kern_return_t
    New(OSObject * instance) override;
    virtual kern_return_t
    Dispatch(const IORPC rpc) override;
};

#endif /* !KERNEL */

class  __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer"))) OSAction_VPhoneAudioDevice_ZtsTimerOccurredInterface : public OSInterface
{
public:
};

struct OSAction_VPhoneAudioDevice_ZtsTimerOccurred_IVars;
struct OSAction_VPhoneAudioDevice_ZtsTimerOccurred_LocalIVars;

class __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer"))) OSAction_VPhoneAudioDevice_ZtsTimerOccurred : public OSAction, public OSAction_VPhoneAudioDevice_ZtsTimerOccurredInterface
{
#if KERNEL
    OSDeclareDefaultStructorsWithDispatch(OSAction_VPhoneAudioDevice_ZtsTimerOccurred);
#endif /* KERNEL */

#if !KERNEL
    friend class OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass;
#endif /* !KERNEL */

public:
#ifdef OSAction_VPhoneAudioDevice_ZtsTimerOccurred_DECLARE_IVARS
OSAction_VPhoneAudioDevice_ZtsTimerOccurred_DECLARE_IVARS
#else /* OSAction_VPhoneAudioDevice_ZtsTimerOccurred_DECLARE_IVARS */
    union
    {
        OSAction_VPhoneAudioDevice_ZtsTimerOccurred_IVars * ivars;
        OSAction_VPhoneAudioDevice_ZtsTimerOccurred_LocalIVars * lvars;
    };
#endif /* OSAction_VPhoneAudioDevice_ZtsTimerOccurred_DECLARE_IVARS */
#if !KERNEL
    static OSMetaClass *
    sGetMetaClass() { return gOSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass; };
    virtual const OSMetaClass *
    getMetaClass() const APPLE_KEXT_OVERRIDE { return gOSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass; };
#endif /* KERNEL */

    using super = OSAction;

#if !KERNEL
    OSAction_VPhoneAudioDevice_ZtsTimerOccurred_Methods
#endif /* !KERNEL */

    OSAction_VPhoneAudioDevice_ZtsTimerOccurred_VirtualMethods
};

#endif /* !__DOCUMENTATION__ */

/* VPhoneAudioDevice.iig:35- */

#endif /* VPhoneAudioDevice_h */
