/* iig(DriverKit-440) generated from VPhoneAudio.iig */

/* VPhoneAudio.iig:1-9 */
// VPhoneAudio.iig — IOUserAudioDriver subclass (manages VPhoneAudioDevice)
#ifndef VPhoneAudio_h
#define VPhoneAudio_h

#include <DriverKit/DriverKit.h>  /* .iig include */
#include <AudioDriverKit/IOUserAudioDriver.h>  /* .iig include */

using namespace AudioDriverKit;

/* source class VPhoneAudio VPhoneAudio.iig:10-16 */

#if __DOCUMENTATION__
#define KERNEL IIG_KERNEL

class VPhoneAudio: public IOUserAudioDriver
{
public:
    virtual bool          init() override;
    virtual void          free() override;
    virtual kern_return_t Start(IOService* provider) override;
    virtual kern_return_t Stop(IOService* provider) override;
};

#undef KERNEL
#else /* __DOCUMENTATION__ */

/* generated class VPhoneAudio VPhoneAudio.iig:10-16 */


#define VPhoneAudio_Start_Args \
        IOService * provider

#define VPhoneAudio_Stop_Args \
        IOService * provider

#define VPhoneAudio_Methods \
\
public:\
\
    virtual kern_return_t\
    Dispatch(const IORPC rpc) APPLE_KEXT_OVERRIDE;\
\
    static kern_return_t\
    _Dispatch(VPhoneAudio * self, const IORPC rpc);\
\
\
protected:\
    /* _Impl methods */\
\
    kern_return_t\
    Start_Impl(IOService_Start_Args);\
\
    kern_return_t\
    Stop_Impl(IOService_Stop_Args);\
\
\
public:\
    /* _Invoke methods */\
\


#define VPhoneAudio_KernelMethods \
\
protected:\
    /* _Impl methods */\
\


#define VPhoneAudio_VirtualMethods \
\
public:\
\
    virtual bool\
    init(\
) APPLE_KEXT_OVERRIDE;\
\
    virtual void\
    free(\
) APPLE_KEXT_OVERRIDE;\
\


#if !KERNEL

extern OSMetaClass          * gVPhoneAudioMetaClass;
extern const OSClassLoadInformation VPhoneAudio_Class;

class VPhoneAudioMetaClass : public OSMetaClass
{
public:
    virtual kern_return_t
    New(OSObject * instance) override;
    virtual kern_return_t
    Dispatch(const IORPC rpc) override;
};

#endif /* !KERNEL */

#if !KERNEL

class  VPhoneAudioInterface : public OSInterface
{
public:
};

struct VPhoneAudio_IVars;
struct VPhoneAudio_LocalIVars;

class VPhoneAudio : public IOUserAudioDriver, public VPhoneAudioInterface
{
#if !KERNEL
    friend class VPhoneAudioMetaClass;
#endif /* !KERNEL */

#if !KERNEL
public:
#ifdef VPhoneAudio_DECLARE_IVARS
VPhoneAudio_DECLARE_IVARS
#else /* VPhoneAudio_DECLARE_IVARS */
    union
    {
        VPhoneAudio_IVars * ivars;
        VPhoneAudio_LocalIVars * lvars;
    };
#endif /* VPhoneAudio_DECLARE_IVARS */
#endif /* !KERNEL */

#if !KERNEL
    static OSMetaClass *
    sGetMetaClass() { return gVPhoneAudioMetaClass; };
#endif /* KERNEL */

    using super = IOUserAudioDriver;

#if !KERNEL
    VPhoneAudio_Methods
    VPhoneAudio_VirtualMethods
#endif /* !KERNEL */

};
#endif /* !KERNEL */


#endif /* !__DOCUMENTATION__ */

/* VPhoneAudio.iig:18- */

#endif /* VPhoneAudio_h */
