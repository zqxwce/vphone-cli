/* iig(DriverKit-440 May 22 2026 10:59:06) generated from VPhoneAudioDevice.iig */

#undef	IIG_IMPLEMENTATION
#define	IIG_IMPLEMENTATION 	VPhoneAudioDevice.iig

#if KERNEL
#include <libkern/c++/OSString.h>
#else
#include <DriverKit/DriverKit.h>
#endif /* KERNEL */
#include <DriverKit/IOReturn.h>
#include <VPhoneAudio/VPhoneAudioDevice.h>


#if __has_builtin(__builtin_load_member_function_pointer)
#define SimpleMemberFunctionCast(cfnty, self, func) (cfnty)__builtin_load_member_function_pointer(self, func)
#else
#define SimpleMemberFunctionCast(cfnty, self, func) ({ union { typeof(func) memfun; cfnty cfun; } pair; pair.memfun = func; pair.cfun; })
#endif


#if !KERNEL
extern OSMetaClass * gOSOrderedSetMetaClass;
extern OSMetaClass * gIOUserAudioCustomPropertyMetaClass;
extern OSMetaClass * gIOUserAudioControlMetaClass;
extern OSMetaClass * gIOUserAudioDriverMetaClass;
extern OSMetaClass * gOSAction_IOUserClient_KernelCompletionMetaClass;
extern OSMetaClass * gOSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass;
#endif /* !KERNEL */

#if !KERNEL

#define VPhoneAudioDevice_QueueNames  ""

#define VPhoneAudioDevice_MethodNames  ""

#define VPhoneAudioDeviceMetaClass_MethodNames  ""

struct OSClassDescription_VPhoneAudioDevice_t
{
    OSClassDescription base;
    uint64_t           methodOptions[2 * 0];
    uint64_t           metaMethodOptions[2 * 0];
    char               queueNames[sizeof(VPhoneAudioDevice_QueueNames)];
    char               methodNames[sizeof(VPhoneAudioDevice_MethodNames)];
    char               metaMethodNames[sizeof(VPhoneAudioDeviceMetaClass_MethodNames)];
};

const struct OSClassDescription_VPhoneAudioDevice_t
OSClassDescription_VPhoneAudioDevice =
{
    .base =
    {
        .descriptionSize         = sizeof(OSClassDescription_VPhoneAudioDevice_t),
        .name                    = "VPhoneAudioDevice",
        .superName               = "IOUserAudioDevice",
        .methodOptionsSize       = 2 * sizeof(uint64_t) * 0,
        .methodOptionsOffset     = __builtin_offsetof(struct OSClassDescription_VPhoneAudioDevice_t, methodOptions),
        .metaMethodOptionsSize   = 2 * sizeof(uint64_t) * 0,
        .metaMethodOptionsOffset = __builtin_offsetof(struct OSClassDescription_VPhoneAudioDevice_t, metaMethodOptions),
        .queueNamesSize       = sizeof(VPhoneAudioDevice_QueueNames),
        .queueNamesOffset     = __builtin_offsetof(struct OSClassDescription_VPhoneAudioDevice_t, queueNames),
        .methodNamesSize         = sizeof(VPhoneAudioDevice_MethodNames),
        .methodNamesOffset       = __builtin_offsetof(struct OSClassDescription_VPhoneAudioDevice_t, methodNames),
        .metaMethodNamesSize     = sizeof(VPhoneAudioDeviceMetaClass_MethodNames),
        .metaMethodNamesOffset   = __builtin_offsetof(struct OSClassDescription_VPhoneAudioDevice_t, metaMethodNames),
        .flags                   = 0*kOSClassCanRemote,
        .resv1                   = {0},
    },
    .methodOptions =
    {
    },
    .metaMethodOptions =
    {
    },
    .queueNames      = VPhoneAudioDevice_QueueNames,
    .methodNames     = VPhoneAudioDevice_MethodNames,
    .metaMethodNames = VPhoneAudioDeviceMetaClass_MethodNames,
};

OSMetaClass * gVPhoneAudioDeviceMetaClass;

static kern_return_t
VPhoneAudioDevice_New(OSMetaClass * instance);

const OSClassLoadInformation
VPhoneAudioDevice_Class = 
{
    .description       = &OSClassDescription_VPhoneAudioDevice.base,
    .metaPointer       = &gVPhoneAudioDeviceMetaClass,
    .version           = 1,
    .instanceSize      = sizeof(VPhoneAudioDevice),

    .resv2             = {0},

    .New               = &VPhoneAudioDevice_New,
    .resv3             = {0},

};

extern const void * const
gVPhoneAudioDevice_Declaration;
const void * const
gVPhoneAudioDevice_Declaration
__attribute__((used,visibility("hidden"),section("__DATA_CONST,__osclassinfo,regular,no_dead_strip"),no_sanitize("address")))
    = &VPhoneAudioDevice_Class;

static kern_return_t
VPhoneAudioDevice_New(OSMetaClass * instance)
{
    if (!new(instance) VPhoneAudioDeviceMetaClass) return (kIOReturnNoMemory);
    return (kIOReturnSuccess);
}

kern_return_t
VPhoneAudioDeviceMetaClass::New(OSObject * instance)
{
    if (!new(instance) VPhoneAudioDevice) return (kIOReturnNoMemory);
    return (kIOReturnSuccess);
}

#endif /* !KERNEL */

#ifdef KERNEL
#define MESSAGE_CONTENT(__field) (messageContent->__field)
#else /* KERNEL */
#define MESSAGE_CONTENT(__field) (message->content.__field)
#endif /* KERNEL */

kern_return_t
VPhoneAudioDevice::Dispatch(const IORPC rpc)
{
    return _Dispatch(this, rpc);
}

kern_return_t
VPhoneAudioDevice::_Dispatch(VPhoneAudioDevice * self, const IORPC rpc)
{
    kern_return_t ret = kIOReturnUnsupported;
#ifdef KERNEL
    IORPCMessage * msg = rpc.kernelContent;
#else /* KERNEL */
    IORPCMessage * msg = IORPCMessageFromMach(rpc.message, false);
#endif /* KERNEL */

    switch (msg->msgid)
    {
        case VPhoneAudioDevice_ZtsTimerOccurred_ID:
#if !KERNEL
        if (self->IsRemote())
        {
            ret = self->OSMetaClassBase::Dispatch(rpc);
            break;
        }
        else
#endif /* !KERNEL */
        {
            ret = IOTimerDispatchSource::TimerOccurred_Invoke(rpc, self, SimpleMemberFunctionCast(IOTimerDispatchSource::TimerOccurred_Handler, *self, &VPhoneAudioDevice::ZtsTimerOccurred_Impl), OSTypeID(OSAction_VPhoneAudioDevice_ZtsTimerOccurred));
            break;
        }

        default:
            ret = IOUserAudioDevice::_Dispatch(self, rpc);
            break;
    }

    return (ret);
}

#if KERNEL
kern_return_t
VPhoneAudioDevice::MetaClass::Dispatch(const IORPC rpc)
{
#else /* KERNEL */
kern_return_t
VPhoneAudioDeviceMetaClass::Dispatch(const IORPC rpc)
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

kern_return_t
VPhoneAudioDevice::CreateActionZtsTimerOccurred(size_t referenceSize, OSAction ** action)
{
    kern_return_t ret;

#if defined(IOKIT_ENABLE_SHARED_PTR)
    OSSharedPtr<OSString>
#else /* defined(IOKIT_ENABLE_SHARED_PTR) */
    OSString *
#endif /* !defined(IOKIT_ENABLE_SHARED_PTR) */
    typeName = OSString::withCString("OSAction_VPhoneAudioDevice_ZtsTimerOccurred");
    if (!typeName) {
        return kIOReturnNoMemory;
    }
    ret = OSAction_VPhoneAudioDevice_ZtsTimerOccurred::CreateWithTypeName(this,
                           VPhoneAudioDevice_ZtsTimerOccurred_ID,
                           IOTimerDispatchSource_TimerOccurred_ID,
                           referenceSize,
#if defined(IOKIT_ENABLE_SHARED_PTR)
                           typeName.get(),
#else /* defined(IOKIT_ENABLE_SHARED_PTR) */
                           typeName,
#endif /* !defined(IOKIT_ENABLE_SHARED_PTR) */
                           action);

#if !defined(IOKIT_ENABLE_SHARED_PTR)
    typeName->release();
#endif /* !defined(IOKIT_ENABLE_SHARED_PTR) */
    return (ret);
}

#if KERNEL
OSDefineMetaClassAndStructors(OSAction_VPhoneAudioDevice_ZtsTimerOccurred, OSAction);
#endif /* KERNEL */

#if !KERNEL

#define OSAction_VPhoneAudioDevice_ZtsTimerOccurred_QueueNames  ""

#define OSAction_VPhoneAudioDevice_ZtsTimerOccurred_MethodNames  ""

#define OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass_MethodNames  ""

struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t
{
    OSClassDescription base;
    uint64_t           methodOptions[2 * 0];
    uint64_t           metaMethodOptions[2 * 0];
    char               queueNames[sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurred_QueueNames)];
    char               methodNames[sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurred_MethodNames)];
    char               metaMethodNames[sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass_MethodNames)];
};

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
const struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t
OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred =
{
    .base =
    {
        .descriptionSize         = sizeof(OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t),
        .name                    = "OSAction_VPhoneAudioDevice_ZtsTimerOccurred",
        .superName               = "OSAction",
        .methodOptionsSize       = 2 * sizeof(uint64_t) * 0,
        .methodOptionsOffset     = __builtin_offsetof(struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t, methodOptions),
        .metaMethodOptionsSize   = 2 * sizeof(uint64_t) * 0,
        .metaMethodOptionsOffset = __builtin_offsetof(struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t, metaMethodOptions),
        .queueNamesSize       = sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurred_QueueNames),
        .queueNamesOffset     = __builtin_offsetof(struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t, queueNames),
        .methodNamesSize         = sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurred_MethodNames),
        .methodNamesOffset       = __builtin_offsetof(struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t, methodNames),
        .metaMethodNamesSize     = sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass_MethodNames),
        .metaMethodNamesOffset   = __builtin_offsetof(struct OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred_t, metaMethodNames),
        .flags                   = 0*kOSClassCanRemote,
        .resv1                   = {0},
    },
    .methodOptions =
    {
    },
    .metaMethodOptions =
    {
    },
    .queueNames      = OSAction_VPhoneAudioDevice_ZtsTimerOccurred_QueueNames,
    .methodNames     = OSAction_VPhoneAudioDevice_ZtsTimerOccurred_MethodNames,
    .metaMethodNames = OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass_MethodNames,
};

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
OSMetaClass * gOSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass;

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
static kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurred_New(OSMetaClass * instance);

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
const OSClassLoadInformation
OSAction_VPhoneAudioDevice_ZtsTimerOccurred_Class = 
{
    .description       = &OSClassDescription_OSAction_VPhoneAudioDevice_ZtsTimerOccurred.base,
    .metaPointer       = &gOSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass,
    .version           = 1,
    .instanceSize      = sizeof(OSAction_VPhoneAudioDevice_ZtsTimerOccurred),

    .resv2             = {0},

    .New               = &OSAction_VPhoneAudioDevice_ZtsTimerOccurred_New,
    .resv3             = {0},

};

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
extern const void * const
gOSAction_VPhoneAudioDevice_ZtsTimerOccurred_Declaration;
 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
const void * const
gOSAction_VPhoneAudioDevice_ZtsTimerOccurred_Declaration
 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
__attribute__((used,visibility("hidden"),section("__DATA_CONST,__osclassinfo,regular,no_dead_strip"),no_sanitize("address")))
    = &OSAction_VPhoneAudioDevice_ZtsTimerOccurred_Class;

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
static kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurred_New(OSMetaClass * instance)
{
    if (!new(instance) OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass) return (kIOReturnNoMemory);
    return (kIOReturnSuccess);
}

 __attribute__((availability(driverkit,introduced=20,message="Type-safe OSAction factory methods are available in DriverKit 20 and newer")))
kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass::New(OSObject * instance)
{
    if (!new(instance) OSAction_VPhoneAudioDevice_ZtsTimerOccurred) return (kIOReturnNoMemory);
    return (kIOReturnSuccess);
}

#endif /* !KERNEL */

#ifdef KERNEL
#define MESSAGE_CONTENT(__field) (messageContent->__field)
#else /* KERNEL */
#define MESSAGE_CONTENT(__field) (message->content.__field)
#endif /* KERNEL */

kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurred::Dispatch(const IORPC rpc)
{
    return _Dispatch(this, rpc);
}

kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurred::_Dispatch(OSAction_VPhoneAudioDevice_ZtsTimerOccurred * self, const IORPC rpc)
{
    kern_return_t ret = kIOReturnUnsupported;
#ifdef KERNEL
    IORPCMessage * msg = rpc.kernelContent;
#else /* KERNEL */
    IORPCMessage * msg = IORPCMessageFromMach(rpc.message, false);
#endif /* KERNEL */

    switch (msg->msgid)
    {

        default:
            ret = OSAction::_Dispatch(self, rpc);
            break;
    }

    return (ret);
}

#if KERNEL
kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurred::MetaClass::Dispatch(const IORPC rpc)
{
#else /* KERNEL */
kern_return_t
OSAction_VPhoneAudioDevice_ZtsTimerOccurredMetaClass::Dispatch(const IORPC rpc)
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



