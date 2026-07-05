/* iig(DriverKit-440 May 22 2026 10:59:06) generated from VPhoneAudio.iig */

#undef	IIG_IMPLEMENTATION
#define	IIG_IMPLEMENTATION 	VPhoneAudio.iig

#if KERNEL
#include <libkern/c++/OSString.h>
#else
#include <DriverKit/DriverKit.h>
#endif /* KERNEL */
#include <DriverKit/IOReturn.h>
#include <VPhoneAudio/VPhoneAudio.h>


#if __has_builtin(__builtin_load_member_function_pointer)
#define SimpleMemberFunctionCast(cfnty, self, func) (cfnty)__builtin_load_member_function_pointer(self, func)
#else
#define SimpleMemberFunctionCast(cfnty, self, func) ({ union { typeof(func) memfun; cfnty cfun; } pair; pair.memfun = func; pair.cfun; })
#endif


#if !KERNEL
extern OSMetaClass * gOSOrderedSetMetaClass;
extern OSMetaClass * gIOUserAudioObjectMetaClass;
extern OSMetaClass * gIOUserAudioDeviceMetaClass;
extern OSMetaClass * gIOUserAudioCustomPropertyMetaClass;
extern OSMetaClass * gOSAction_IOUserClient_KernelCompletionMetaClass;
#endif /* !KERNEL */

#if !KERNEL

#define VPhoneAudio_QueueNames  ""

#define VPhoneAudio_MethodNames  ""

#define VPhoneAudioMetaClass_MethodNames  ""

struct OSClassDescription_VPhoneAudio_t
{
    OSClassDescription base;
    uint64_t           methodOptions[2 * 0];
    uint64_t           metaMethodOptions[2 * 0];
    char               queueNames[sizeof(VPhoneAudio_QueueNames)];
    char               methodNames[sizeof(VPhoneAudio_MethodNames)];
    char               metaMethodNames[sizeof(VPhoneAudioMetaClass_MethodNames)];
};

const struct OSClassDescription_VPhoneAudio_t
OSClassDescription_VPhoneAudio =
{
    .base =
    {
        .descriptionSize         = sizeof(OSClassDescription_VPhoneAudio_t),
        .name                    = "VPhoneAudio",
        .superName               = "IOUserAudioDriver",
        .methodOptionsSize       = 2 * sizeof(uint64_t) * 0,
        .methodOptionsOffset     = __builtin_offsetof(struct OSClassDescription_VPhoneAudio_t, methodOptions),
        .metaMethodOptionsSize   = 2 * sizeof(uint64_t) * 0,
        .metaMethodOptionsOffset = __builtin_offsetof(struct OSClassDescription_VPhoneAudio_t, metaMethodOptions),
        .queueNamesSize       = sizeof(VPhoneAudio_QueueNames),
        .queueNamesOffset     = __builtin_offsetof(struct OSClassDescription_VPhoneAudio_t, queueNames),
        .methodNamesSize         = sizeof(VPhoneAudio_MethodNames),
        .methodNamesOffset       = __builtin_offsetof(struct OSClassDescription_VPhoneAudio_t, methodNames),
        .metaMethodNamesSize     = sizeof(VPhoneAudioMetaClass_MethodNames),
        .metaMethodNamesOffset   = __builtin_offsetof(struct OSClassDescription_VPhoneAudio_t, metaMethodNames),
        .flags                   = 0*kOSClassCanRemote,
        .resv1                   = {0},
    },
    .methodOptions =
    {
    },
    .metaMethodOptions =
    {
    },
    .queueNames      = VPhoneAudio_QueueNames,
    .methodNames     = VPhoneAudio_MethodNames,
    .metaMethodNames = VPhoneAudioMetaClass_MethodNames,
};

OSMetaClass * gVPhoneAudioMetaClass;

static kern_return_t
VPhoneAudio_New(OSMetaClass * instance);

const OSClassLoadInformation
VPhoneAudio_Class = 
{
    .description       = &OSClassDescription_VPhoneAudio.base,
    .metaPointer       = &gVPhoneAudioMetaClass,
    .version           = 1,
    .instanceSize      = sizeof(VPhoneAudio),

    .resv2             = {0},

    .New               = &VPhoneAudio_New,
    .resv3             = {0},

};

extern const void * const
gVPhoneAudio_Declaration;
const void * const
gVPhoneAudio_Declaration
__attribute__((used,visibility("hidden"),section("__DATA_CONST,__osclassinfo,regular,no_dead_strip"),no_sanitize("address")))
    = &VPhoneAudio_Class;

static kern_return_t
VPhoneAudio_New(OSMetaClass * instance)
{
    if (!new(instance) VPhoneAudioMetaClass) return (kIOReturnNoMemory);
    return (kIOReturnSuccess);
}

kern_return_t
VPhoneAudioMetaClass::New(OSObject * instance)
{
    if (!new(instance) VPhoneAudio) return (kIOReturnNoMemory);
    return (kIOReturnSuccess);
}

#endif /* !KERNEL */

#ifdef KERNEL
#define MESSAGE_CONTENT(__field) (messageContent->__field)
#else /* KERNEL */
#define MESSAGE_CONTENT(__field) (message->content.__field)
#endif /* KERNEL */

kern_return_t
VPhoneAudio::Dispatch(const IORPC rpc)
{
    return _Dispatch(this, rpc);
}

kern_return_t
VPhoneAudio::_Dispatch(VPhoneAudio * self, const IORPC rpc)
{
    kern_return_t ret = kIOReturnUnsupported;
#ifdef KERNEL
    IORPCMessage * msg = rpc.kernelContent;
#else /* KERNEL */
    IORPCMessage * msg = IORPCMessageFromMach(rpc.message, false);
#endif /* KERNEL */

    switch (msg->msgid)
    {
        case IOService_Start_ID:
        {
            ret = IOService::Start_Invoke(rpc, self, SimpleMemberFunctionCast(IOService::Start_Handler, *self, &VPhoneAudio::Start_Impl));
            break;
        }
        case IOService_Stop_ID:
        {
            ret = IOService::Stop_Invoke(rpc, self, SimpleMemberFunctionCast(IOService::Stop_Handler, *self, &VPhoneAudio::Stop_Impl));
            break;
        }

        default:
            ret = IOUserAudioDriver::_Dispatch(self, rpc);
            break;
    }

    return (ret);
}

#if KERNEL
kern_return_t
VPhoneAudio::MetaClass::Dispatch(const IORPC rpc)
{
#else /* KERNEL */
kern_return_t
VPhoneAudioMetaClass::Dispatch(const IORPC rpc)
{
#endif /* !KERNEL */

    kern_return_t ret = kIOReturnUnsupported;
#ifdef KERNEL
    IORPCMessage * msg = rpc.kernelContent;
#else /* KERNEL */
    IORPCMessage * msg = IORPCMessageFromMach(rpc.message, false);
#endif /* KERNEL */

    switch (msg->msgid)
    {

        default:
            ret = OSMetaClassBase::Dispatch(rpc);
            break;
    }

    return (ret);
}



