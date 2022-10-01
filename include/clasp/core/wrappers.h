/*
    File: wrappers.h
*/

/*
Copyright (c) 2014, Christian E. Schafmeister
 
CLASP is free software; you can redistribute it and/or
modify it under the terms of the GNU Library General Public
License as published by the Free Software Foundation; either
version 2 of the License, or (at your option) any later version.
 
See directory 'clasp/licenses' for full details.
 
The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
/* -^- */
#ifndef core_wrappers_H
#define core_wrappers_H

#include <functional>
#include <clasp/core/lispDefinitions.h>
#include <clasp/core/exceptions.h>
#include <clasp/core/symbolToEnumConverter.h>
#include <clasp/core/activationFrame.h>
#include <clasp/clbind/apply.h>
#include <clasp/clbind/function.h>
#include <clasp/clbind/policies.h>

//#define DEBUG_METHOIDS 1




namespace core {

class TranslationFunctor_O : public core::GlobalEntryPointBase_O {
  LISP_CLASS(core,CorePkg,TranslationFunctor_O,"TranslationFunctor",GlobalEntryPointBase_O);
public:
  typedef TranslationFunctor_O MyType;
  typedef core::T_O* (*Type)(core::T_O* arg);
public:
  Type fptr;
public:
  TranslationFunctor_O(Type ptr) : fptr(ptr) {
    printf("%s:%d:%s What do I do with CodePtr\n", __FILE__, __LINE__, __FUNCTION__ );
    //
    // Initialize the _EntryPoints with the addresses of this classes entrypoints
    //
    this->_EntryPoints.template setup<MyType>();
    this->validateCodePointer((void**)&this->fptr,sizeof(this->fptr));
    };
  public:
    typedef BuiltinClosure_O TemplatedBase;
    virtual size_t templatedSizeof() const override { return sizeof(TranslationFunctor_O); };
  
    virtual void fixupInternalsForSnapshotSaveLoad( snapshotSaveLoad::Fixup* fixup ) {
      this->Base::fixupInternalsForSnapshotSaveLoad(fixup);
      this->fixupOneCodePointer( fixup, (void**)&this->fptr );
    }
    static inline LCC_RETURN LISP_CALLING_CONVENTION() {
      TranslationFunctor_O* closure = gctools::untag_general<TranslationFunctor_O*>((TranslationFunctor_O*)lcc_closure);
      core::T_O* arg0 = lcc_args[0];
      return gctools::return_type((closure->fptr)(arg0),1);
    }
    static inline LISP_ENTRY_0() {
      wrong_number_of_arguments(lcc_closure,0,1);
    };
    static inline LISP_ENTRY_1() {
      TranslationFunctor_O* closure = gctools::untag_general<TranslationFunctor_O*>((TranslationFunctor_O*)lcc_closure);
      return gctools::return_type((closure->fptr)(lcc_farg0),1);
    }
    static inline LISP_ENTRY_2() {
      wrong_number_of_arguments(lcc_closure,2,1);
    };
    static inline LISP_ENTRY_3() {
      wrong_number_of_arguments(lcc_closure,3,1);
    };
    static inline LISP_ENTRY_4() {
      wrong_number_of_arguments(lcc_closure,4,1);
    };
    static inline LISP_ENTRY_5() {
      wrong_number_of_arguments(lcc_closure,5,1);
    };
  };

};


#include <clasp/core/arguments.h>
#include <clasp/core/lambdaListHandler.fwd.h>


namespace core {
//#include <clasp/core/wrappers_functoids.h>

template <int DispatchOn, typename FunctionPtrType, typename Policies, typename ArgumentHandler>
class TEMPLATED_FUNCTION_VariadicMethoid : public BuiltinClosure_O {
public:
  typedef BuiltinClosure_O TemplatedBase;
  size_t templatedSizeof() const { return sizeof(*this); };
};

};

namespace core {
template <int DispatchOn, typename RT, typename OT, typename... ARGS>
class TEMPLATED_FUNCTION_VariadicMethoid <DispatchOn, RT(OT::*)(ARGS...), core::policy::clasp_policy, clbind::LambdaListHandlerWrapper > : public BuiltinClosure_O {
public:
  typedef TEMPLATED_FUNCTION_VariadicMethoid<DispatchOn, RT(OT::*)(ARGS...), core::policy::clasp_policy, clbind::LambdaListHandlerWrapper > MyType;
  typedef BuiltinClosure_O TemplatedBase;
public:
  virtual const char* describe() const {return "VariadicMethoid";};
  typedef RT(OT::*MethodType)(ARGS...) ;
  MethodType mptr;
public:
  enum { NumParams = sizeof...(ARGS)+1 };
  TEMPLATED_FUNCTION_VariadicMethoid(GlobalEntryPoint_sp ep, MethodType ptr) : BuiltinClosure_O(ep), mptr(ptr) {
    this->validateCodePointer((void**)&this->mptr,sizeof(this->mptr));
  };
  virtual size_t templatedSizeof() const { return sizeof(*this);};
  virtual void fixupInternalsForSnapshotSaveLoad( snapshotSaveLoad::Fixup* fixup ) {
    this->fixupOneCodePointer( fixup, (void**)&this->mptr, sizeof(this->mptr) );
  }
  static inline gctools::return_type LISP_CALLING_CONVENTION()
  {
    MyType* closure = gctools::untag_general<MyType*>((MyType*)lcc_closure);
    INCREMENT_FUNCTION_CALL_COUNTER(closure);
    MAKE_STACK_FRAME(frame,sizeof...(ARGS)+1);
    MAKE_SPECIAL_BINDINGS_HOLDER(numSpecialBindings, specialBindingsVLA,
                                 lisp_lambdaListHandlerNumberOfSpecialVariables(closure->_lambdaListHandler));
    core::StackFrameDynamicScopeManager scope(closure->_lambdaListHandler,
                                              numSpecialBindings,
                                              specialBindingsVLA,
                                              frame,
                                              sizeof...(ARGS)+1);
    lambdaListHandler_createBindings(closure->asSmartPtr(),closure->_lambdaListHandler,&scope, lcc_nargs, lcc_args );
    OT& oto = *gc::As<gctools::smart_ptr<OT>>(frame->arg(0));
    std::tuple<translate::from_object<ARGS>...> all_args = clbind::arg_tuple<1,clbind::policies<>,ARGS...>::goFrame(frame->arguments(0));
    return clbind::method_apply_and_return<RT,core::policy::clasp_policy,decltype(closure->mptr),OT,decltype(all_args)>::go(std::move(closure->mptr),std::move(oto),std::move(all_args));
  }
  static inline LISP_ENTRY_0() {
    return entry_point_n(lcc_closure,0,NULL);
  }
  static inline LISP_ENTRY_1() {
    core::T_O* args[1] = {lcc_farg0};
    return entry_point_n(lcc_closure,1,args);
  }
  static inline LISP_ENTRY_2() {
    core::T_O* args[2] = {lcc_farg0,lcc_farg1};
    return entry_point_n(lcc_closure,2,args);
  }
  static inline LISP_ENTRY_3() {
    core::T_O* args[3] = {lcc_farg0,lcc_farg1,lcc_farg2};
    return entry_point_n(lcc_closure,3,args);
  }
  static inline LISP_ENTRY_4() {
    core::T_O* args[4] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3};
    return entry_point_n(lcc_closure,4,args);
  }
  static inline LISP_ENTRY_5() {
    core::T_O* args[5] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3,lcc_farg4};
    return entry_point_n(lcc_closure,5,args);
  }
};


template <int DispatchOn, typename RT, typename OT, typename... ARGS>
class TEMPLATED_FUNCTION_VariadicMethoid <DispatchOn, RT(OT::*)(ARGS...) const, core::policy::clasp_policy, clbind::LambdaListHandlerWrapper >
: public BuiltinClosure_O {
public:
  typedef TEMPLATED_FUNCTION_VariadicMethoid<DispatchOn, RT(OT::*)(ARGS...) const, core::policy::clasp_policy, clbind::LambdaListHandlerWrapper > MyType;
  typedef BuiltinClosure_O TemplatedBase;
public:
  virtual const char* describe() const {return "VariadicMethoid";};
  typedef RT(OT::*MethodType)(ARGS...) const ;
  MethodType mptr;
public:
  enum { NumParams = sizeof...(ARGS)+1 };
  TEMPLATED_FUNCTION_VariadicMethoid(GlobalEntryPoint_sp ep, MethodType ptr) : BuiltinClosure_O(ep), mptr(ptr) {
    this->validateCodePointer((void**)&this->mptr,sizeof(this->mptr));
  };
  virtual size_t templatedSizeof() const { return sizeof(*this);};
  virtual void fixupInternalsForSnapshotSaveLoad( snapshotSaveLoad::Fixup* fixup ) {
    this->fixupOneCodePointer(fixup,(void**)&this->mptr,sizeof(this->mptr));
  }
  static inline gctools::return_type LISP_CALLING_CONVENTION()
  {
    MyType* closure = gctools::untag_general<MyType*>((MyType*)lcc_closure);
    INCREMENT_FUNCTION_CALL_COUNTER(closure);
    MAKE_STACK_FRAME(frame,sizeof...(ARGS)+1);
    MAKE_SPECIAL_BINDINGS_HOLDER(numSpecialBindings, specialBindingsVLA,
                                 lisp_lambdaListHandlerNumberOfSpecialVariables(closure->_lambdaListHandler));
    core::StackFrameDynamicScopeManager scope(closure->_lambdaListHandler,
                                              numSpecialBindings,
                                              specialBindingsVLA,
                                              frame,
                                              sizeof...(ARGS)+1);
    lambdaListHandler_createBindings(closure->asSmartPtr(),closure->_lambdaListHandler,&scope, lcc_nargs, lcc_args );
    OT& oto = *gc::As<gctools::smart_ptr<OT>>(frame->arg(0));
    std::tuple<translate::from_object<ARGS>...> all_args = clbind::arg_tuple<1,clbind::policies<>,ARGS...>::goFrame(frame->arguments(0));
    return clbind::method_apply_and_return<RT,core::policy::clasp_policy,decltype(closure->mptr),OT,decltype(all_args)>::go(std::move(closure->mptr),std::move(oto),std::move(all_args));
  }
    static inline LISP_ENTRY_0() {
    return entry_point_n(lcc_closure,0,NULL);
  }
  static inline LISP_ENTRY_1() {
    core::T_O* args[1] = {lcc_farg0};
    return entry_point_n(lcc_closure,1,args);
  }
  static inline LISP_ENTRY_2() {
    core::T_O* args[2] = {lcc_farg0,lcc_farg1};
    return entry_point_n(lcc_closure,2,args);
  }
  static inline LISP_ENTRY_3() {
    core::T_O* args[3] = {lcc_farg0,lcc_farg1,lcc_farg2};
    return entry_point_n(lcc_closure,3,args);
  }
  static inline LISP_ENTRY_4() {
    core::T_O* args[4] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3};
    return entry_point_n(lcc_closure,4,args);
  }
  static inline LISP_ENTRY_5() {
    core::T_O* args[5] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3,lcc_farg4};
    return entry_point_n(lcc_closure,5,args);
  }

};

};


namespace core {
template <int DispatchOn, typename RT, typename OT, typename... ARGS>
class TEMPLATED_FUNCTION_VariadicMethoid <DispatchOn, RT(OT::*)(ARGS...), core::policy::clasp_policy, clbind::BytecodeWrapper > : public BuiltinClosure_O {
public:
  typedef TEMPLATED_FUNCTION_VariadicMethoid<DispatchOn, RT(OT::*)(ARGS...), core::policy::clasp_policy, clbind::BytecodeWrapper > MyType;
  typedef BuiltinClosure_O TemplatedBase;
public:
  virtual const char* describe() const {return "VariadicMethoid";};
  typedef RT(OT::*MethodType)(ARGS...) ;
  MethodType mptr;
public:
  enum { NumParams = sizeof...(ARGS)+1 };
  TEMPLATED_FUNCTION_VariadicMethoid(GlobalEntryPoint_sp ep, MethodType ptr) : BuiltinClosure_O(ep), mptr(ptr) {
    this->validateCodePointer((void**)&this->mptr,sizeof(this->mptr));
  };
  virtual size_t templatedSizeof() const { return sizeof(*this);};
  virtual void fixupInternalsForSnapshotSaveLoad( snapshotSaveLoad::Fixup* fixup ) {
    this->fixupOneCodePointer( fixup, (void**)&this->mptr, sizeof(this->mptr) );
  }
  static inline gctools::return_type LISP_CALLING_CONVENTION()
  {
    MyType* closure = gctools::untag_general<MyType*>((MyType*)lcc_closure);
    INCREMENT_FUNCTION_CALL_COUNTER(closure);
    T_sp dispatchArg((gctools::Tagged)lcc_args[0]);
    OT& oto = *gc::As<gctools::smart_ptr<OT>>(dispatchArg);
    std::tuple<translate::from_object<ARGS>...> all_args = clbind::arg_tuple<1,clbind::policies<>,ARGS...>::goFrame(lcc_args);
    return clbind::method_apply_and_return<RT,core::policy::clasp_policy,decltype(closure->mptr),OT,decltype(all_args)>::go(std::move(closure->mptr),std::move(oto),std::move(all_args));
  }
  static inline LISP_ENTRY_0() {
    return entry_point_n(lcc_closure,0,NULL);
  }
  static inline LISP_ENTRY_1() {
    core::T_O* args[1] = {lcc_farg0};
    return entry_point_n(lcc_closure,1,args);
  }
  static inline LISP_ENTRY_2() {
    core::T_O* args[2] = {lcc_farg0,lcc_farg1};
    return entry_point_n(lcc_closure,2,args);
  }
  static inline LISP_ENTRY_3() {
    core::T_O* args[3] = {lcc_farg0,lcc_farg1,lcc_farg2};
    return entry_point_n(lcc_closure,3,args);
  }
  static inline LISP_ENTRY_4() {
    core::T_O* args[4] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3};
    return entry_point_n(lcc_closure,4,args);
  }
  static inline LISP_ENTRY_5() {
    core::T_O* args[5] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3,lcc_farg4};
    return entry_point_n(lcc_closure,5,args);
  }
};


template <int DispatchOn, typename RT, typename OT, typename... ARGS>
class TEMPLATED_FUNCTION_VariadicMethoid <DispatchOn, RT(OT::*)(ARGS...) const, core::policy::clasp_policy, clbind::BytecodeWrapper >
: public BuiltinClosure_O {
public:
  typedef TEMPLATED_FUNCTION_VariadicMethoid<DispatchOn, RT(OT::*)(ARGS...) const, core::policy::clasp_policy, clbind::BytecodeWrapper > MyType;
  typedef BuiltinClosure_O TemplatedBase;
public:
  virtual const char* describe() const {return "VariadicMethoid";};
  typedef RT(OT::*MethodType)(ARGS...) const ;
  MethodType mptr;
public:
  enum { NumParams = sizeof...(ARGS)+1 };
  TEMPLATED_FUNCTION_VariadicMethoid(GlobalEntryPoint_sp ep, MethodType ptr) : BuiltinClosure_O(ep), mptr(ptr) {
    this->validateCodePointer((void**)&this->mptr,sizeof(this->mptr));
  };
  virtual size_t templatedSizeof() const { return sizeof(*this);};
  virtual void fixupInternalsForSnapshotSaveLoad( snapshotSaveLoad::Fixup* fixup ) {
    this->fixupOneCodePointer(fixup,(void**)&this->mptr,sizeof(this->mptr));
  }
  static inline gctools::return_type LISP_CALLING_CONVENTION()
  {
    MyType* closure = gctools::untag_general<MyType*>((MyType*)lcc_closure);
    INCREMENT_FUNCTION_CALL_COUNTER(closure);
    T_sp dispatchArg((gctools::Tagged)lcc_args[0]);
    OT& oto = *gc::As<gctools::smart_ptr<OT>>(dispatchArg);
    std::tuple<translate::from_object<ARGS>...> all_args = clbind::arg_tuple<1,clbind::policies<>,ARGS...>::goFrame(lcc_args);
    return clbind::method_apply_and_return<RT,core::policy::clasp_policy,decltype(closure->mptr),OT,decltype(all_args)>::go(std::move(closure->mptr),std::move(oto),std::move(all_args));
  }
    static inline LISP_ENTRY_0() {
    return entry_point_n(lcc_closure,0,NULL);
  }
  static inline LISP_ENTRY_1() {
    core::T_O* args[1] = {lcc_farg0};
    return entry_point_n(lcc_closure,1,args);
  }
  static inline LISP_ENTRY_2() {
    core::T_O* args[2] = {lcc_farg0,lcc_farg1};
    return entry_point_n(lcc_closure,2,args);
  }
  static inline LISP_ENTRY_3() {
    core::T_O* args[3] = {lcc_farg0,lcc_farg1,lcc_farg2};
    return entry_point_n(lcc_closure,3,args);
  }
  static inline LISP_ENTRY_4() {
    core::T_O* args[4] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3};
    return entry_point_n(lcc_closure,4,args);
  }
  static inline LISP_ENTRY_5() {
    core::T_O* args[5] = {lcc_farg0,lcc_farg1,lcc_farg2,lcc_farg3,lcc_farg4};
    return entry_point_n(lcc_closure,5,args);
  }

};

};

namespace core {

  inline void wrap_translator(const string &packageName, const string &name, core::T_O* (*fp)(core::T_O*), const string& filename,  const string &arguments = "", const string &declares = "", const string &docstring = "", const string &sourceFile = "", int sourceLine = 0) {
    Symbol_sp symbol = lispify_intern(name, packageName);
    using VariadicType = TranslationFunctor_O;
    FunctionDescription_sp fdesc = makeFunctionDescription(symbol,nil<T_O>());
    auto entry = gctools::GC<VariadicType>::allocate(fp);
    lisp_bytecode_defun( symbol_function, clbind::DefaultWrapper::BytecodeP, symbol, packageName, entry, arguments, declares, docstring, sourceFile, sourceLine, 1 );
  }



// this is used in gc_interface.cc expose_function
 template <typename RT, typename... ARGS>
void wrap_function_LambdaListHandler(const string &packageName, const string &name, RT (*fp)(ARGS...), const string &arguments = "", const string &declares = "", const string &docstring = "", const string &sourceFile = "", int sourceLine = 0) {
   maybe_register_symbol_using_dladdr(*(void**)&fp,sizeof(fp),name);
   Symbol_sp symbol = _lisp->intern(name, packageName);
   printf("%s:%d:%s %s\n", __FILE__, __LINE__, __FUNCTION__, name.c_str());
   using PureOutValuePack = typename clbind::inValueTrueFalseMaskPack< sizeof...(ARGS), clbind::policies<>>::type;
   using VariadicType = clbind::TEMPLATED_FUNCTION_VariadicFunctor<RT(*)(ARGS...),core::policy::clasp_policy, PureOutValuePack, clbind::LambdaListHandlerWrapper >;
   FunctionDescription_sp fdesc = makeFunctionDescription(symbol,nil<T_O>());
   auto entry = gctools::GC<VariadicType>::allocate(fp,fdesc,nil<T_O>(),unbound<LambdaListHandler_O>());
   lisp_bytecode_defun( core::symbol_function, clbind::LambdaListHandlerWrapper::BytecodeP, symbol, packageName, entry, arguments, declares, docstring, sourceFile, sourceLine, sizeof...(ARGS));
 }

 template <typename RT, typename... ARGS>
void wrap_function_BytecodeWrapper(const string &packageName, const string &name, RT (*fp)(ARGS...), const string &arguments = "", const string &declares = "", const string &docstring = "", const string &sourceFile = "", int sourceLine = 0) {
   maybe_register_symbol_using_dladdr(*(void**)&fp,sizeof(fp),name);
   Symbol_sp symbol = _lisp->intern(name, packageName);
   printf("%s:%d:%s %s\n", __FILE__, __LINE__, __FUNCTION__, name.c_str());
   using PureOutValuePack = typename clbind::inValueTrueFalseMaskPack< sizeof...(ARGS), clbind::policies<>>::type;
   using VariadicType = clbind::TEMPLATED_FUNCTION_VariadicFunctor<RT(*)(ARGS...),core::policy::clasp_policy, PureOutValuePack, clbind::BytecodeWrapper>;
   FunctionDescription_sp fdesc = makeFunctionDescription(symbol,nil<T_O>());
   auto entry = gctools::GC<VariadicType>::allocate(fp,fdesc,nil<T_O>(),unbound<LambdaListHandler_O>());
   lisp_bytecode_defun( core::symbol_function, clbind::BytecodeWrapper::BytecodeP, symbol, packageName, entry, arguments, declares, docstring, sourceFile, sourceLine, sizeof...(ARGS));
 }

 template <typename RT, typename... ARGS>
void wrap_function(const string &packageName, const string &name, RT (*fp)(ARGS...), const string &arguments = "", const string &declares = "", const string &docstring = "", const string &sourceFile = "", int sourceLine = 0) {
   maybe_register_symbol_using_dladdr(*(void**)&fp,sizeof(fp),name);
   Symbol_sp symbol = _lisp->intern(name, packageName);
   using PureOutValuePack = typename clbind::inValueTrueFalseMaskPack< sizeof...(ARGS), clbind::policies<>>::type;
   using VariadicType = clbind::TEMPLATED_FUNCTION_VariadicFunctor<RT(*)(ARGS...),core::policy::clasp_policy, PureOutValuePack, clbind::DefaultWrapper>;
   FunctionDescription_sp fdesc = makeFunctionDescription(symbol,nil<T_O>());
   auto entry = gctools::GC<VariadicType>::allocate(fp,fdesc,nil<T_O>(),unbound<LambdaListHandler_O>());
   lisp_bytecode_defun( core::symbol_function, clbind::DefaultWrapper::BytecodeP, symbol, packageName, entry, arguments, declares, docstring, sourceFile, sourceLine, sizeof...(ARGS));
 }

// this is used in gc_interface.cc expose_function_setf
  template <typename RT, typename... ARGS>
void wrap_function_setf(const string &packageName, const string &name, RT (*fp)(ARGS...), const string &arguments = "", const string &declares = "", const string &docstring = "", const string &sourceFile = "", int sourceLine = 0) {
    maybe_register_symbol_using_dladdr(*(void**)&fp,sizeof(fp),name);
    Symbol_sp symbol = _lisp->intern(name, packageName);
    using PureOutValuePack = typename clbind::inValueTrueFalseMaskPack< sizeof...(ARGS), clbind::policies<>>::type;
    using VariadicType = clbind::TEMPLATED_FUNCTION_VariadicFunctor<RT(*)(ARGS...),core::policy::clasp_policy,PureOutValuePack,clbind::DefaultWrapper>;
    FunctionDescription_sp fdesc = makeFunctionDescription(symbol,nil<T_O>());
    auto entry = gctools::GC<VariadicType>::allocate(fp,fdesc,nil<T_O>(),unbound<LambdaListHandler_O>());
    lisp_bytecode_defun( core::symbol_function_setf, clbind::DefaultWrapper::BytecodeP, symbol, packageName, entry, arguments, declares, docstring, sourceFile, sourceLine, sizeof...(ARGS));
  }



};

template <int DispatchOn, typename FunctionPtrType, typename Policies, typename ArgumentHandler >
class gctools::GCStamp<core::TEMPLATED_FUNCTION_VariadicMethoid<DispatchOn, FunctionPtrType, Policies, ArgumentHandler>> {
public:
  static gctools::GCStampEnum const StampWtag = gctools::GCStamp<typename core::TEMPLATED_FUNCTION_VariadicMethoid<DispatchOn, FunctionPtrType, Policies, ArgumentHandler>::TemplatedBase>::StampWtag;
};

namespace core {

class Function_O;

// -----------------------------------
//
// Macro stuff
//
//
// Wrapper for ActivationFrameMacroPtr

// basically like wrap_function.
inline void defmacro(const string &packageName, const string &name, T_mv (*fp)(List_sp, T_sp env), const string &arguments, const string &declares, const string &docstring, const string &sourcePathname, int lineno) {
  maybe_register_symbol_using_dladdr(*(void**)&fp,sizeof(fp),name);
  Symbol_sp symbol = lispify_intern(name, packageName);
  using PureOutValuePack = typename clbind::inValueTrueFalseMaskPack< 2, clbind::policies<>>::type;
  using VariadicType = clbind::TEMPLATED_FUNCTION_VariadicFunctor<T_mv(*)(List_sp,T_sp),core::policy::clasp_policy, PureOutValuePack, clbind::DefaultWrapper>;
  FunctionDescription_sp fdesc = makeFunctionDescription(symbol,nil<T_O>());
  auto entry = gctools::GC<VariadicType>::allocate(fp,fdesc,nil<T_O>(),unbound<LambdaListHandler_O>());
  lisp_bytecode_defun( symbol_function_macro, clbind::DefaultWrapper::BytecodeP, symbol, packageName, entry, arguments, declares, docstring);
  validateFunctionDescription(__FILE__,__LINE__,entry);
}
 
template <int N>
struct DispatchOn {
  enum { value = N };
};

// ----------------------------------------
// ----------------------------------------
// ----------------------------------------
// ----------------------------------------


extern Symbol_sp& _sym_STARallCxxClassesSTAR;

struct names_ {
  std::vector<std::string> _Names;
  names_(const std::string& name1) : _Names({name1}) {};
  names_(const std::string& name1, const std::string& name2) : _Names({name1,name2}) {};
};

template <typename OT>
class class_ {
public:
  typedef OT wrapped_type;

private:
  Symbol_sp _ClassSymbol;

public:
  void setup_class(const string &makerName = "") {
    _G();
    if (IS_SYMBOL_UNDEFINED(OT::static_classSymbol())) {
      SIMPLE_ERROR_SPRINTF("Attempting to add methods for class that isn't defined yet");
    }

    this->_ClassSymbol = OT::static_classSymbol();

    reg::lisp_registerClassSymbol<OT>(this->_ClassSymbol);

    /*! Accumulate all of the classes in reverse order of how they were initialized
	      in the core::*all-cxx-classes* variable */
    lisp_pushClassSymbolOntoSTARallCxxClassesSTAR(OT::static_classSymbol());

//
// If the class isn't in the class table then add it
//
    if (makerName != "") {
      // use make-<className>
      std::string magic_maker_name = core::magic_name(makerName,OT::static_packageName());
      std::string pkg_part;
      std::string symbol_part;
      core::colon_split( magic_maker_name, pkg_part, symbol_part);
      wrap_function(pkg_part,symbol_part, &new_LispObject<OT>);
    }
  }

  //
  //
  // ctor
  //
  //

  class_() {
    _G();
    this->setup_class("");
  }

  class_(const string &makerName) {
    _G();
    this->setup_class(makerName);
  }
 
  // non-const function dispatch on parameter 0
  template <typename RT, class... ARGS>
  class_& def(const names_& names, RT (OT::*mp)(ARGS...),
              string const &lambda_list = "", const string &declares = "", const string &docstring = "", bool autoExport = true)
  {
    for (auto& name : names._Names ) {
      maybe_register_symbol_using_dladdr(*(void**)&mp,sizeof(mp),name);
      std::string pkgName;
      std::string symbolName;
      core::colon_split(name,pkgName,symbolName);
      if (pkgName == "") {
        pkgName = symbol_packageName(this->_ClassSymbol);
      }
      Symbol_sp symbol = _lisp->intern(symbolName,pkgName);
      using VariadicType = TEMPLATED_FUNCTION_VariadicMethoid<0, RT (OT::*)(ARGS...), core::policy::clasp_policy, clbind::DefaultWrapper >;
      GlobalEntryPoint_sp entryPoint = makeGlobalEntryPointAndFunctionDescription<VariadicType>(symbol,nil<core::T_O>());
      BuiltinClosure_sp m = gc::As<BuiltinClosure_sp>(gc::GC<VariadicType>::allocate(entryPoint,mp));
      lisp_defineSingleDispatchMethod( clbind::DefaultWrapper(), symbol, this->_ClassSymbol, m, 0, true, lambda_list, declares, docstring, autoExport, sizeof...(ARGS)+1);
      validateFunctionDescription(__FILE__,__LINE__,m);
    }
    return *this;
  }
 
  // const function dispatch on parameter 0
  template <typename RT, class... ARGS>
  class_& def(const names_& names, RT (OT::*mp)(ARGS...) const,
              string const &lambda_list = "", const string &declares = "", const string &docstring = "", bool autoExport = true)
  {
    for (auto& name : names._Names ) {
      maybe_register_symbol_using_dladdr(*(void**)&mp,sizeof(mp),name);
      std::string pkgName;
      std::string symbolName;
      core::colon_split(name,pkgName,symbolName);
      if (pkgName == "") {
        pkgName = symbol_packageName(this->_ClassSymbol);
      }
      Symbol_sp symbol = _lisp->intern(symbolName,pkgName);
      using VariadicType = TEMPLATED_FUNCTION_VariadicMethoid<0, RT (OT::*)(ARGS...) const, core::policy::clasp_policy, clbind::DefaultWrapper >;
      GlobalEntryPoint_sp entryPoint = makeGlobalEntryPointAndFunctionDescription<VariadicType>(symbol,nil<core::T_O>());
      BuiltinClosure_sp m = gc::As<BuiltinClosure_sp>(gc::GC<VariadicType>::allocate(entryPoint,mp));
      lisp_defineSingleDispatchMethod(clbind::DefaultWrapper(), symbol, this->_ClassSymbol, m, 0, true, lambda_list, declares, docstring, autoExport, sizeof...(ARGS)+1);
      validateFunctionDescription(__FILE__,__LINE__,m);
    }
    return *this;
  }
};

template <typename oclass>
void defaultExposeCando(LispPtr lisp) {
  _G();
  // Only expose the class, don't create any methods
  // By default put class in the Cl package
  class_<oclass>();
}

struct EnumValueDefinition {
  string _Name;
  int _Value;
};

template <typename X>
class enum_ {
private:
  SymbolToEnumConverter_sp _Converter;
  Symbol_sp _PredefinedConverterSymbolId;

public:
  enum_(Symbol_sp symbol, const string &title) {
    _G();
    this->_PredefinedConverterSymbolId = symbol;
    this->_Converter = SymbolToEnumConverter_O::create(title);
    lisp_defparameter(symbol, this->_Converter);
  }

  enum_ &value(Symbol_sp const &sym, X value) {
    _G();
    lisp_extendSymbolToEnumConverter(this->_Converter, sym, sym, static_cast<int>(value));
    return *this;
  }
  enum_ &value(Symbol_sp const &name, Symbol_sp const &archiveName, X value) {
    _G();
    lisp_extendSymbolToEnumConverter(this->_Converter, name, archiveName, value);
    return *this;
  }
  Symbol_sp symbolFromEnum(int value) {
    _G();
    return lisp_lookupSymbolForEnum(this->_PredefinedConverterSymbolId, (int)(value));
  }
};
};

//ostream& operator<<(ostream& out, gctools::smart_ptr<core::T_O>

#endif // wrappers_h
