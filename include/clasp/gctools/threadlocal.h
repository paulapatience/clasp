#ifndef gctools_threadlocal_H
#define gctools_threadlocal_H

#include <signal.h>
#include <functional>
#include <clasp/gctools/threadlocal.fwd.h>

typedef core::T_O*(*T_OStartUp)(core::T_O*);
typedef void(*voidStartUp)(void);


namespace core {

#ifdef DEBUG_DYN_ENV_STACK
extern bool global_debug_dyn_env_stack;
#endif

#define STARTUP_FUNCTION_CAPACITY_INIT 128
#define STARTUP_FUNCTION_CAPACITY_MULTIPLIER 2
  struct StartUp {
    typedef enum {T_O_function, void_function} FunctionEnum;
    FunctionEnum _Type;
    size_t       _Position;
    void*        _Function;
    StartUp() {};
    StartUp(FunctionEnum type, size_t p, void* f) : _Type(type), _Position(p), _Function(f) {};
    bool operator<(const StartUp& other) {
      return this->_Position < other._Position;
    }
  };

  struct StartupInfo {
    size_t _capacity;
    size_t _count;
    StartUp* _functions;

  StartupInfo() : _capacity(0), _count(0), _functions(NULL) {};
  };
};

namespace core {
struct CleanupFunctionNode {
  std::function<void(void)> _CleanupFunction;
  CleanupFunctionNode*      _Next;
  CleanupFunctionNode(const std::function<void(void)>& cleanup, CleanupFunctionNode* next)
    : _CleanupFunction(cleanup), _Next(next) {};

};
};

namespace llvmo {
class ObjectFile_O;
typedef gctools::smart_ptr<ObjectFile_O> ObjectFile_sp;
class CodeBase_O;
typedef gctools::smart_ptr<CodeBase_O> CodeBase_sp;

};
namespace core {

struct VirtualMachine {
  static constexpr size_t MaxStackWords = 16384; // 16K words for now.
  core::T_O**    _StackBottom;
  size_t         _StackBytes;
  core::T_O**    _StackTop;
  core::T_O**    _FramePointer;
  core::T_O**    _StackPointer;
  core::T_sp     _CurrentFunction;
  core::T_O**    _Literals;
  unsigned char* _PC;

  inline void push(core::T_O* value) {
    this->_StackPointer--;
    *this->_StackPointer = value;
  }

  inline core::T_O* pop() {
    core::T_O* value = *this->_StackPointer;
    this->_StackPointer++;
    return value;
  }

  VirtualMachine();
  ~VirtualMachine();

};



#define IHS_BACKTRACE_SIZE 16
  struct ThreadLocalState {

    core::T_sp            _ObjectFiles;
    mp::Process_sp        _Process;
    DynamicBindingStack   _Bindings;
    /*! Pending interrupts */
    List_sp               _PendingInterrupts;
    /*! Save CONS records so we don't need to do allocations
        to add to _PendingInterrupts */
    List_sp               _SparePendingInterruptRecords; // signal_queue on ECL
    List_sp               _BufferStr8NsPool;
    List_sp               _BufferStrWNsPool;
    StringOutputStream_sp _BFormatStringOutputStream;
    StringOutputStream_sp _WriteToStringOutputStream;

    MultipleValues _MultipleValues;
    void* _sigaltstack_buffer;
    size_t  _unwinds;
    stack_t _original_stack;
    std::string       _initializer_symbol;
    void*             _object_file_start;
    size_t            _object_file_size;
    gctools::GCRootsInModule*  _GCRootsInModule;
    StartupInfo       _Startup;
    bool              _Breakstep; // Should we check for breaks?
    // What frame are we stepping over? NULL means step-into mode.
    void*             _BreakstepFrame;
    // Stuff for SJLJ unwinding
    List_sp           _DynEnvStackBottom;
    T_sp              _UnwindDest;
    size_t            _UnwindDestIndex;
#ifdef DEBUG_IHS
    // Save the last return address before IHS screws up
    void*                    _IHSBacktrace[IHS_BACKTRACE_SIZE];
#endif
    size_t                 _xorshf_x; // Marsaglia's xorshf generator
    size_t                 _xorshf_y;
    size_t                 _xorshf_z;
    CleanupFunctionNode*   _CleanupFunctions;
    mp::SpinLock _SparePendingInterruptRecordsSpinLock;
    uint64_t   _BytesAllocated;
    uint64_t            _Tid;
    uintptr_t           _BacktraceBasePointer;
    VirtualMachine      _VM;
    
#ifdef DEBUG_MONITOR_SUPPORT
    // When enabled, maintain a thread-local map of strings to FILE*
    // used for logging. This is so that per-thread log files can be
    // generated.  These log files are automatically closed when the
    // thread exits.
    std::map<std::string,FILE*> _MonitorFiles;
#endif

  public:
    // Methods
    ThreadLocalState(bool dummy);
    void finish_initialization_main_thread(core::T_sp theNilObject);
    ThreadLocalState();
    void initialize_thread(mp::Process_sp process, bool initialize_GCRoots);

    void dynEnvStackTest(core::T_sp val) const;
    void dynEnvStackSet(core::T_sp val) {
#ifdef DEBUG_DYN_ENV_STACK
      if (core::global_debug_dyn_env_stack)
        this->dynEnvStackTest(val);
#endif
      this->_DynEnvStackBottom = val;
    }
    core::T_sp dynEnvStackGet() const {
#ifdef DEBUG_DYN_ENV_STACK
      if (core::global_debug_dyn_env_stack)
        this->dynEnvStackTest(this->_DynEnvStackBottom);
#endif
      return this->_DynEnvStackBottom;
    }
    
    uint32_t random();

    llvmo::ObjectFile_sp topObjectFile();
    void pushObjectFile(llvmo::ObjectFile_sp of);
    void popObjectFile();
    inline DynamicBindingStack& bindings() { return this->_Bindings; };
    
    ~ThreadLocalState();
  };

  void thread_local_register_cleanup(const std::function<void(void)>& cleanup);
  void thread_local_invoke_and_clear_cleanup();

}; // namespace core


namespace gctools {

  void registerBytesAllocated(size_t bytes);
};


struct ThreadManager {
  struct Worker {
#ifdef USE_BOEHM
    GC_stack_base _StackBase;
#endif
    gctools::ThreadLocalStateLowLevel _StateLowLevel;
    core::ThreadLocalState _State;
    // Worker must be allocated at the top of the worker thread function
    // It uses RAII to register/deregister our thread
    Worker() : _StateLowLevel((void*)this), _State(false) {
//      printf("%s:%d:%s Starting\n", __FILE__, __LINE__, __FUNCTION__ );
#ifdef USE_BOEHM
      GC_get_stack_base(&this->_StackBase);
      GC_register_my_thread(&this->_StackBase);
      my_thread_low_level = &this->_StateLowLevel;
#endif
    };
    ~Worker() {
//      printf("%s:%d:%s Stopping\n", __FILE__, __LINE__, __FUNCTION__ );
#ifdef USE_BOEHM
      GC_unregister_my_thread();
#endif
    };
  };
  void register_thread(std::thread& th) {
    // Do nothing for now
  };
  void unregister_thread(std::thread& th) {
    // Do nothing for now
  };
};





#endif
