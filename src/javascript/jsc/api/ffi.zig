const Bun = @This();
const default_allocator = @import("../../../global.zig").default_allocator;
const bun = @import("../../../global.zig");
const Environment = bun.Environment;
const NetworkThread = @import("http").NetworkThread;
const Global = bun.Global;
const strings = bun.strings;
const string = bun.string;
const Output = @import("../../../global.zig").Output;
const MutableString = @import("../../../global.zig").MutableString;
const std = @import("std");
const Allocator = std.mem.Allocator;
const IdentityContext = @import("../../../identity_context.zig").IdentityContext;
const Fs = @import("../../../fs.zig");
const Resolver = @import("../../../resolver/resolver.zig");
const ast = @import("../../../import_record.zig");
const NodeModuleBundle = @import("../../../node_module_bundle.zig").NodeModuleBundle;
const MacroEntryPoint = @import("../../../bundler.zig").MacroEntryPoint;
const logger = @import("../../../logger.zig");
const Api = @import("../../../api/schema.zig").Api;
const options = @import("../../../options.zig");
const Bundler = @import("../../../bundler.zig").Bundler;
const ServerEntryPoint = @import("../../../bundler.zig").ServerEntryPoint;
const js_printer = @import("../../../js_printer.zig");
const js_parser = @import("../../../js_parser.zig");
const js_ast = @import("../../../js_ast.zig");
const hash_map = @import("../../../hash_map.zig");
const http = @import("../../../http.zig");
const NodeFallbackModules = @import("../../../node_fallbacks.zig");
const ImportKind = ast.ImportKind;
const Analytics = @import("../../../analytics/analytics_thread.zig");
const ZigString = @import("../../../jsc.zig").ZigString;
const Runtime = @import("../../../runtime.zig");
const Router = @import("./router.zig");
const ImportRecord = ast.ImportRecord;
const DotEnv = @import("../../../env_loader.zig");
const ParseResult = @import("../../../bundler.zig").ParseResult;
const PackageJSON = @import("../../../resolver/package_json.zig").PackageJSON;
const MacroRemap = @import("../../../resolver/package_json.zig").MacroMap;
const WebCore = @import("../../../jsc.zig").WebCore;
const Request = WebCore.Request;
const Response = WebCore.Response;
const Headers = WebCore.Headers;
const Fetch = WebCore.Fetch;
const FetchEvent = WebCore.FetchEvent;
const js = @import("../../../jsc.zig").C;
const JSC = @import("../../../jsc.zig");
const JSError = @import("../base.zig").JSError;
const d = @import("../base.zig").d;
const MarkedArrayBuffer = @import("../base.zig").MarkedArrayBuffer;
const getAllocator = @import("../base.zig").getAllocator;
const JSValue = @import("../../../jsc.zig").JSValue;
const NewClass = @import("../base.zig").NewClass;
const Microtask = @import("../../../jsc.zig").Microtask;
const JSGlobalObject = @import("../../../jsc.zig").JSGlobalObject;
const ExceptionValueRef = @import("../../../jsc.zig").ExceptionValueRef;
const JSPrivateDataPtr = @import("../../../jsc.zig").JSPrivateDataPtr;
const ZigConsoleClient = @import("../../../jsc.zig").ZigConsoleClient;
const Node = @import("../../../jsc.zig").Node;
const ZigException = @import("../../../jsc.zig").ZigException;
const ZigStackTrace = @import("../../../jsc.zig").ZigStackTrace;
const ErrorableResolvedSource = @import("../../../jsc.zig").ErrorableResolvedSource;
const ResolvedSource = @import("../../../jsc.zig").ResolvedSource;
const JSPromise = @import("../../../jsc.zig").JSPromise;
const JSInternalPromise = @import("../../../jsc.zig").JSInternalPromise;
const JSModuleLoader = @import("../../../jsc.zig").JSModuleLoader;
const JSPromiseRejectionOperation = @import("../../../jsc.zig").JSPromiseRejectionOperation;
const Exception = @import("../../../jsc.zig").Exception;
const ErrorableZigString = @import("../../../jsc.zig").ErrorableZigString;
const ZigGlobalObject = @import("../../../jsc.zig").ZigGlobalObject;
const VM = @import("../../../jsc.zig").VM;
const JSFunction = @import("../../../jsc.zig").JSFunction;
const Config = @import("../config.zig");
const URL = @import("../../../url.zig").URL;
const Transpiler = @import("./transpiler.zig");
const VirtualMachine = @import("../javascript.zig").VirtualMachine;
const IOTask = JSC.IOTask;
const ComptimeStringMap = @import("../../../comptime_string_map.zig").ComptimeStringMap;

const TCC = @import("../../../../tcc.zig");

/// This is the entry point for generated FFI callback functions
/// We want to avoid potentially causing LLVM to not inline our regular calls to JSC.C.JSObjectCallAsFunction
/// to do that, we use a different pointer for the callback function
/// which is this noinline wrapper
noinline fn bun_call(
    ctx: JSC.C.JSContextRef,
    function: JSC.C.JSObjectRef,
    count: usize,
    argv: [*c]const JSC.C.JSValueRef,
) callconv(.C) JSC.C.JSObjectRef {
    var exception = [1]JSC.C.JSValueRef{null};
    Output.debug("[bun_call] {d} args\n", .{count});
    return JSC.C.JSObjectCallAsFunction(ctx, function, JSC.JSValue.jsUndefined().asObjectRef(), count, argv, &exception);
}

comptime {
    if (!JSC.is_bindgen) {
        _ = bun_call;
        @export(bun_call, .{ .name = "bun_call" });
    }
}

pub const FFI = struct {
    dylib: std.DynLib,
    functions: std.StringArrayHashMapUnmanaged(Function) = .{},
    closed: bool = false,

    pub const Class = JSC.NewClass(
        FFI,
        .{ .name = "class" },
        .{ .call = JSC.wrapWithHasContainer(FFI, "close", false, true, true) },
        .{},
    );

    pub fn callback(globalThis: *JSGlobalObject, interface: JSC.JSValue, js_callback: JSC.JSValue) JSValue {
        if (!interface.isObject()) {
            return JSC.toInvalidArguments("Expected object", .{}, globalThis.ref());
        }

        if (js_callback.isEmptyOrUndefinedOrNull() or !js_callback.isCallable(globalThis.vm())) {
            return JSC.toInvalidArguments("Expected callback function", .{}, globalThis.ref());
        }

        const allocator = VirtualMachine.vm.allocator;
        var function: Function = undefined;
        var func = &function;

        if (generateSymbolForFunction(globalThis, allocator, interface, func) catch ZigString.init("Out of memory").toErrorInstance(globalThis)) |val| {
            return val;
        }

        // TODO: WeakRefHandle that automatically frees it?
        JSC.C.JSValueProtect(globalThis.ref(), js_callback.asObjectRef());
        func.base_name = "";

        func.compileCallback(allocator, globalThis, js_callback.asObjectRef().?) catch return ZigString.init("Out of memory").toErrorInstance(globalThis);
        switch (func.step) {
            .failed => |err| {
                JSC.C.JSValueUnprotect(globalThis.ref(), js_callback.asObjectRef());
                const message = ZigString.init(err.msg).toErrorInstance(globalThis);

                func.deinit(allocator);

                return message;
            },
            .pending => {
                JSC.C.JSValueUnprotect(globalThis.ref(), js_callback.asObjectRef());
                func.deinit(allocator);
                return ZigString.init("Failed to compile, but not sure why. Please report this bug").toErrorInstance(globalThis);
            },
            .compiled => {
                var function_ = bun.default_allocator.create(Function) catch unreachable;
                function_.* = func.*;
                return JSC.JSValue.jsNumber(@bitCast(f64, @as(usize, @ptrToInt(function_.step.compiled.ptr))));
            },
        }
    }

    pub fn close(this: *FFI) JSValue {
        if (this.closed) {
            return JSC.JSValue.jsUndefined();
        }
        this.closed = true;
        this.dylib.close();

        const allocator = VirtualMachine.vm.allocator;

        for (this.functions.values()) |*val| {
            val.deinit(allocator);
        }
        this.functions.deinit(allocator);

        return JSC.JSValue.jsUndefined();
    }

    pub fn printCallback(global: *JSGlobalObject, object: JSC.JSValue) JSValue {
        const allocator = VirtualMachine.vm.allocator;

        if (object.isEmptyOrUndefinedOrNull() or !object.isObject()) {
            return JSC.toInvalidArguments("Expected an object", .{}, global.ref());
        }

        var function: Function = undefined;
        if (generateSymbolForFunction(global, allocator, object, &function) catch ZigString.init("Out of memory").toErrorInstance(global)) |val| {
            return val;
        }

        var arraylist = std.ArrayList(u8).init(allocator);
        defer arraylist.deinit();
        var writer = arraylist.writer();

        function.base_name = "my_callback_function";

        function.printCallbackSourceCode(&writer) catch {
            return ZigString.init("Error while printing code").toErrorInstance(global);
        };
        return ZigString.init(arraylist.items).toValueGC(global);
    }

    pub fn print(global: *JSGlobalObject, object: JSC.JSValue, is_callback_val: ?JSC.JSValue) JSValue {
        const allocator = VirtualMachine.vm.allocator;
        if (is_callback_val) |is_callback| {
            if (is_callback.toBoolean()) {
                return printCallback(global, object);
            }
        }

        if (object.isEmptyOrUndefinedOrNull() or !object.isObject()) {
            return JSC.toInvalidArguments("Expected an options object with symbol names", .{}, global.ref());
        }

        var symbols = std.StringArrayHashMapUnmanaged(Function){};
        if (generateSymbols(global, &symbols, object) catch JSC.JSValue.zero) |val| {
            // an error while validating symbols
            for (symbols.keys()) |key| {
                allocator.free(bun.constStrToU8(key));
            }
            symbols.clearAndFree(allocator);
            return val;
        }

        var zig_strings = allocator.alloc(ZigString, symbols.count()) catch unreachable;
        for (symbols.values()) |*function, i| {
            var arraylist = std.ArrayList(u8).init(allocator);
            var writer = arraylist.writer();
            function.printSourceCode(&writer) catch {
                // an error while generating source code
                for (symbols.keys()) |key| {
                    allocator.free(bun.constStrToU8(key));
                }
                for (zig_strings) |zig_string| {
                    allocator.free(bun.constStrToU8(zig_string.slice()));
                }
                for (symbols.values()) |*function_| {
                    function_.arg_types.deinit(allocator);
                }

                symbols.clearAndFree(allocator);
                return ZigString.init("Error while printing code").toErrorInstance(global);
            };
            zig_strings[i] = ZigString.init(arraylist.items);
        }

        const ret = JSC.JSValue.createStringArray(global, zig_strings.ptr, zig_strings.len, true);

        for (symbols.keys()) |key| {
            allocator.free(bun.constStrToU8(key));
        }
        for (zig_strings) |zig_string| {
            allocator.free(bun.constStrToU8(zig_string.slice()));
        }
        for (symbols.values()) |*function_| {
            function_.arg_types.deinit(allocator);
            if (function_.step == .compiled) {
                allocator.free(function_.step.compiled.buf);
            }
        }
        symbols.clearAndFree(allocator);

        return ret;
    }

    // pub fn dlcompile(global: *JSGlobalObject, object: JSC.JSValue) JSValue {
    //     const allocator = VirtualMachine.vm.allocator;

    //     if (object.isEmptyOrUndefinedOrNull() or !object.isObject()) {
    //         return JSC.toInvalidArguments("Expected an options object with symbol names", .{}, global.ref());
    //     }

    //     var symbols = std.StringArrayHashMapUnmanaged(Function){};
    //     if (generateSymbols(global, &symbols, object) catch JSC.JSValue.zero) |val| {
    //         // an error while validating symbols
    //         for (symbols.keys()) |key| {
    //             allocator.free(bun.constStrToU8(key));
    //         }
    //         symbols.clearAndFree(allocator);
    //         return val;
    //     }

    // }

    pub fn open(global: *JSGlobalObject, name_str: ZigString, object: JSC.JSValue) JSC.JSValue {
        const allocator = VirtualMachine.vm.allocator;
        var name_slice = name_str.toSlice(allocator);
        defer name_slice.deinit();

        if (name_slice.len == 0) {
            return JSC.toInvalidArguments("Invalid library name", .{}, global.ref());
        }

        if (object.isEmptyOrUndefinedOrNull() or !object.isObject()) {
            return JSC.toInvalidArguments("Expected an options object with symbol names", .{}, global.ref());
        }

        const name = name_slice.sliceZ();
        var symbols = std.StringArrayHashMapUnmanaged(Function){};
        if (generateSymbols(global, &symbols, object) catch JSC.JSValue.zero) |val| {
            // an error while validating symbols
            for (symbols.keys()) |key| {
                allocator.free(bun.constStrToU8(key));
            }
            symbols.clearAndFree(allocator);
            return val;
        }
        if (symbols.count() == 0) {
            return JSC.toInvalidArguments("Expected at least one symbol", .{}, global.ref());
        }

        var dylib = std.DynLib.open(name) catch {
            return JSC.toInvalidArguments("Failed to open library", .{}, global.ref());
        };

        var obj = JSC.JSValue.c(JSC.C.JSObjectMake(global.ref(), null, null));
        JSC.C.JSValueProtect(global.ref(), obj.asObjectRef());
        // var has_checked = false;
        defer JSC.C.JSValueUnprotect(global.ref(), obj.asObjectRef());
        for (symbols.values()) |*function| {
            var resolved_symbol = dylib.lookup(*anyopaque, function.base_name) orelse {
                const ret = JSC.toInvalidArguments("Symbol \"{s}\" not found in \"{s}\"", .{ std.mem.span(function.base_name), name_slice.slice() }, global.ref());
                for (symbols.values()) |*value| {
                    allocator.free(bun.constStrToU8(std.mem.span(value.base_name)));
                    value.arg_types.clearAndFree(allocator);
                }
                symbols.clearAndFree(allocator);
                dylib.close();
                return ret;
            };

            function.symbol_from_dynamic_library = resolved_symbol;
            // if (!has_checked and VirtualMachine.vm.rareData().needs_to_copy_libtcc1 orelse true) {
            //     has_checked = true;
            //     VirtualMachine.vm.rareData().needs_to_copy_libtcc1 = false;
            //     if (VirtualMachine.vm.bundler.env.get("BUN_INSTALL")) |bun_install_dir| {
            //         maybeCopyLibtcc1(bun_install_dir);
            //     }
            // }
            function.compile(allocator) catch |err| {
                const ret = JSC.toInvalidArguments("{s} when compiling symbol \"{s}\" in \"{s}\"", .{
                    std.mem.span(@errorName(err)),
                    std.mem.span(function.base_name),
                    name_slice.slice(),
                }, global.ref());
                for (symbols.values()) |*value| {
                    allocator.free(bun.constStrToU8(std.mem.span(value.base_name)));
                    value.arg_types.clearAndFree(allocator);
                }
                symbols.clearAndFree(allocator);
                dylib.close();
                return ret;
            };
            switch (function.step) {
                .failed => |err| {
                    for (symbols.values()) |*value| {
                        allocator.free(bun.constStrToU8(std.mem.span(value.base_name)));
                        value.arg_types.clearAndFree(allocator);
                    }
                    symbols.clearAndFree(allocator);
                    dylib.close();
                    const res = ZigString.init(err.msg).toErrorInstance(global);
                    function.deinit(allocator);
                    return res;
                },
                .pending => {
                    for (symbols.values()) |*value| {
                        allocator.free(bun.constStrToU8(std.mem.span(value.base_name)));
                        value.arg_types.clearAndFree(allocator);
                    }
                    symbols.clearAndFree(allocator);
                    dylib.close();
                    return ZigString.init("Failed to compile (nothing happend!)").toErrorInstance(global);
                },
                .compiled => |compiled| {
                    var cb = JSC.C.JSObjectMakeFunctionWithCallback(global.ref(), null, @ptrCast(JSC.C.JSObjectCallAsFunctionCallback, compiled.ptr));

                    obj.put(global, &ZigString.init(std.mem.span(function.base_name)), JSC.JSValue.cast(cb));
                },
            }
        }

        var lib = allocator.create(FFI) catch unreachable;
        lib.* = .{
            .dylib = dylib,
            .functions = symbols,
        };

        var close_object = JSC.JSValue.c(Class.make(global.ref(), lib));

        return JSC.JSValue.createObject2(global, &ZigString.init("close"), &ZigString.init("symbols"), close_object, obj);
    }
    pub fn generateSymbolForFunction(global: *JSGlobalObject, allocator: std.mem.Allocator, value: JSC.JSValue, function: *Function) !?JSValue {
        var abi_types = std.ArrayListUnmanaged(ABIType){};

        if (value.get(global, "args")) |args| {
            if (args.isEmptyOrUndefinedOrNull() or !args.jsType().isArray()) {
                return ZigString.init("Expected an object with \"args\" as an array").toErrorInstance(global);
            }

            var array = args.arrayIterator(global);

            try abi_types.ensureTotalCapacityPrecise(allocator, array.len);
            while (array.next()) |val| {
                if (val.isEmptyOrUndefinedOrNull()) {
                    abi_types.clearAndFree(allocator);
                    return ZigString.init("param must be a string (type name) or number").toErrorInstance(global);
                }

                if (val.isAnyInt()) {
                    const int = val.toInt32();
                    switch (int) {
                        0...13 => {
                            abi_types.appendAssumeCapacity(@intToEnum(ABIType, int));
                            continue;
                        },
                        else => {
                            abi_types.clearAndFree(allocator);
                            return ZigString.init("invalid ABI type").toErrorInstance(global);
                        },
                    }
                }

                if (!val.jsType().isStringLike()) {
                    abi_types.clearAndFree(allocator);
                    return ZigString.init("param must be a string (type name) or number").toErrorInstance(global);
                }

                var type_name = val.toSlice(global, allocator);
                defer type_name.deinit();
                abi_types.appendAssumeCapacity(ABIType.label.get(type_name.slice()) orelse {
                    abi_types.clearAndFree(allocator);
                    return JSC.toTypeError(JSC.Node.ErrorCode.ERR_INVALID_ARG_VALUE, "Unknown type {s}", .{type_name.slice()}, global.ref());
                });
            }
        }
        // var function
        var return_type = ABIType.@"void";

        if (value.get(global, "return_type")) |ret_value| brk: {
            if (ret_value.isAnyInt()) {
                const int = ret_value.toInt32();
                switch (int) {
                    0...13 => {
                        return_type = @intToEnum(ABIType, int);
                        break :brk;
                    },
                    else => {
                        abi_types.clearAndFree(allocator);
                        return ZigString.init("invalid ABI type").toErrorInstance(global);
                    },
                }
            }

            var ret_slice = ret_value.toSlice(global, allocator);
            defer ret_slice.deinit();
            return_type = ABIType.label.get(ret_slice.slice()) orelse {
                abi_types.clearAndFree(allocator);
                return JSC.toTypeError(JSC.Node.ErrorCode.ERR_INVALID_ARG_VALUE, "Unknown return type {s}", .{ret_slice.slice()}, global.ref());
            };
        }

        function.* = Function{
            .base_name = "",
            .arg_types = abi_types,
            .return_type = return_type,
        };
        return null;
    }
    pub fn generateSymbols(global: *JSGlobalObject, symbols: *std.StringArrayHashMapUnmanaged(Function), object: JSC.JSValue) !?JSValue {
        const allocator = VirtualMachine.vm.allocator;

        var keys = JSC.C.JSObjectCopyPropertyNames(global.ref(), object.asObjectRef());
        defer JSC.C.JSPropertyNameArrayRelease(keys);
        const count = JSC.C.JSPropertyNameArrayGetCount(keys);

        try symbols.ensureTotalCapacity(allocator, count);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            var property_name_ref = JSC.C.JSPropertyNameArrayGetNameAtIndex(keys, i);
            defer JSC.C.JSStringRelease(property_name_ref);
            const len = JSC.C.JSStringGetLength(property_name_ref);
            if (len == 0) continue;
            var prop = JSC.C.JSStringGetCharacters8Ptr(property_name_ref)[0..len];

            var value = JSC.JSValue.c(JSC.C.JSObjectGetProperty(global.ref(), object.asObjectRef(), property_name_ref, null));
            if (value.isEmptyOrUndefinedOrNull()) {
                return JSC.toTypeError(JSC.Node.ErrorCode.ERR_INVALID_ARG_VALUE, "Expected an object for key \"{s}\"", .{prop}, global.ref());
            }

            var function: Function = undefined;
            if (try generateSymbolForFunction(global, allocator, value, &function)) |val| {
                return val;
            }
            function.base_name = try allocator.dupeZ(u8, prop);

            symbols.putAssumeCapacity(std.mem.span(function.base_name), function);
        }

        return null;
    }

    pub const Function = struct {
        symbol_from_dynamic_library: ?*anyopaque = null,
        base_name: [:0]const u8 = "",
        state: ?*TCC.TCCState = null,

        return_type: ABIType,
        arg_types: std.ArrayListUnmanaged(ABIType) = .{},
        step: Step = Step{ .pending = {} },

        pub var lib_dirZ: [*:0]const u8 = "";

        pub fn deinit(val: *Function, allocator: std.mem.Allocator) void {
            if (std.mem.span(val.base_name).len > 0) allocator.free(bun.constStrToU8(std.mem.span(val.base_name)));

            val.arg_types.deinit(allocator);

            if (val.state) |state| {
                TCC.tcc_delete(state);
                val.state = null;
            }

            if (val.step == .compiled) {
                // allocator.free(val.step.compiled.buf);
                if (val.step.compiled.js_function) |js_function| {
                    JSC.C.JSValueUnprotect(@ptrCast(JSC.C.JSContextRef, val.step.compiled.js_context.?), @ptrCast(JSC.C.JSObjectRef, js_function));
                }
            }

            if (val.step == .failed and val.step.failed.allocated) {
                allocator.free(val.step.failed.msg);
            }
        }

        pub const Step = union(enum) {
            pending: void,
            compiled: struct {
                ptr: *anyopaque,
                buf: []u8,
                js_function: ?*anyopaque = null,
                js_context: ?*anyopaque = null,
            },
            failed: struct {
                msg: []const u8,
                allocated: bool = false,
            },
        };

        const FFI_HEADER: string = @embedFile("./FFI.h");
        pub inline fn ffiHeader() string {
            if (comptime Environment.isDebug) {
                var dirpath = std.fs.path.dirname(@src().file).?;
                var env = std.process.getEnvMap(default_allocator) catch unreachable;

                const dir = std.mem.replaceOwned(
                    u8,
                    default_allocator,
                    dirpath,
                    "jarred",
                    env.get("USER").?,
                ) catch unreachable;
                var runtime_path = std.fs.path.join(default_allocator, &[_]string{ dir, "FFI.h" }) catch unreachable;
                const file = std.fs.openFileAbsolute(runtime_path, .{}) catch @panic("Missing bun/src/javascript/jsc/api/FFI.h.");
                defer file.close();
                return file.readToEndAlloc(default_allocator, (file.stat() catch unreachable).size) catch unreachable;
            } else {
                return FFI_HEADER;
            }
        }

        pub fn handleTCCError(ctx: ?*anyopaque, message: [*c]const u8) callconv(.C) void {
            var this = bun.cast(*Function, ctx.?);
            var msg = std.mem.span(message);
            if (msg.len > 0) {
                var offset: usize = 0;
                // the message we get from TCC sometimes has garbage in it
                // i think because we're doing in-memory compilation
                while (offset < msg.len) : (offset += 1) {
                    if (msg[offset] > 0x20 and msg[offset] < 0x7f) break;
                }
                msg = msg[offset..];
            }

            this.step = .{ .failed = .{ .msg = VirtualMachine.vm.allocator.dupe(u8, msg) catch unreachable, .allocated = true } };
        }

        extern fn pthread_jit_write_protect_np(enable: bool) callconv(.C) void;

        const tcc_options = "-std=c11 -nostdlib -Wl,--export-all-symbols";

        pub fn compile(
            this: *Function,
            allocator: std.mem.Allocator,
        ) !void {
            var source_code = std.ArrayList(u8).init(allocator);
            var source_code_writer = source_code.writer();
            try this.printSourceCode(&source_code_writer);

            try source_code.append(0);
            defer source_code.deinit();

            var state = TCC.tcc_new() orelse return error.TCCMissing;
            TCC.tcc_set_options(state, tcc_options);
            // addSharedLibPaths(state);
            TCC.tcc_set_error_func(state, this, handleTCCError);
            this.state = state;
            defer {
                if (this.step == .failed) {
                    TCC.tcc_delete(state);
                    this.state = null;
                }
            }

            _ = TCC.tcc_set_output_type(state, TCC.TCC_OUTPUT_MEMORY);

            const compilation_result = TCC.tcc_compile_string(
                state,
                source_code.items.ptr,
            );
            // did tcc report an error?
            if (this.step == .failed) {
                return;
            }

            // did tcc report failure but never called the error callback?
            if (compilation_result == -1) {
                this.step = .{ .failed = .{ .msg = "tcc returned -1, which means it failed" } };
                return;
            }
            CompilerRT.inject(state);
            _ = TCC.tcc_add_symbol(state, this.base_name, this.symbol_from_dynamic_library.?);
            if (this.step == .failed) {
                return;
            }

            var relocation_size = TCC.tcc_relocate(state, null);
            if (this.step == .failed) {
                return;
            }

            if (relocation_size < 0) {
                this.step = .{ .failed = .{ .msg = "tcc_relocate returned a negative value" } };
                return;
            }

            var bytes: []u8 = try allocator.rawAlloc(@intCast(usize, relocation_size), 16, 16, 0);
            defer {
                if (this.step == .failed) {
                    allocator.free(bytes);
                }
            }

            if (comptime Environment.isAarch64 and Environment.isMac) {
                pthread_jit_write_protect_np(false);
            }
            _ = TCC.tcc_relocate(state, bytes.ptr);
            if (comptime Environment.isAarch64 and Environment.isMac) {
                pthread_jit_write_protect_np(true);
            }

            var formatted_symbol_name = try std.fmt.allocPrintZ(allocator, "bun_gen_{s}", .{std.mem.span(this.base_name)});
            defer allocator.free(formatted_symbol_name);
            var symbol = TCC.tcc_get_symbol(state, formatted_symbol_name) orelse {
                this.step = .{ .failed = .{ .msg = "missing generated symbol in source code" } };

                return;
            };

            this.step = .{
                .compiled = .{
                    .ptr = symbol,
                    .buf = bytes,
                },
            };
            return;
        }

        const CompilerRT = struct {
            noinline fn memset(
                dest: [*]u8,
                c: u8,
                byte_count: usize,
            ) callconv(.C) void {
                @memset(dest, c, byte_count);
            }

            noinline fn memcpy(
                noalias dest: [*]u8,
                noalias source: [*]const u8,
                byte_count: usize,
            ) callconv(.C) void {
                @memcpy(dest, source, byte_count);
            }

            pub fn inject(state: *TCC.TCCState) void {
                _ = TCC.tcc_add_symbol(state, "memset", &memset);
                _ = TCC.tcc_add_symbol(state, "memcpy", &memcpy);
            }
        };

        pub fn compileCallback(
            this: *Function,
            allocator: std.mem.Allocator,
            js_context: *anyopaque,
            js_function: *anyopaque,
        ) !void {
            Output.debug("welcome", .{});
            var source_code = std.ArrayList(u8).init(allocator);
            var source_code_writer = source_code.writer();
            try this.printCallbackSourceCode(&source_code_writer);
            Output.debug("helllooo", .{});
            try source_code.append(0);
            // defer source_code.deinit();
            var state = TCC.tcc_new() orelse return error.TCCMissing;
            TCC.tcc_set_options(state, tcc_options);
            TCC.tcc_set_error_func(state, this, handleTCCError);
            this.state = state;
            defer {
                if (this.step == .failed) {
                    TCC.tcc_delete(state);
                    this.state = null;
                }
            }

            _ = TCC.tcc_set_output_type(state, TCC.TCC_OUTPUT_MEMORY);
            CompilerRT.inject(state);

            const compilation_result = TCC.tcc_compile_string(
                state,
                source_code.items.ptr,
            );
            Output.debug("compile", .{});
            // did tcc report an error?
            if (this.step == .failed) {
                return;
            }

            // did tcc report failure but never called the error callback?
            if (compilation_result == -1) {
                this.step = .{ .failed = .{ .msg = "tcc returned -1, which means it failed" } };

                return;
            }
            Output.debug("here", .{});

            _ = TCC.tcc_add_symbol(state, "bun_call", JSC.C.JSObjectCallAsFunction);
            _ = TCC.tcc_add_symbol(state, "cachedJSContext", js_context);
            _ = TCC.tcc_add_symbol(state, "cachedCallbackFunction", js_function);

            var relocation_size = TCC.tcc_relocate(state, null);
            if (relocation_size == 0) return;
            var bytes: []u8 = try allocator.rawAlloc(@intCast(usize, relocation_size), 16, 16, 0);
            defer {
                if (this.step == .failed) {
                    allocator.free(bytes);
                }
            }

            if (comptime Environment.isAarch64 and Environment.isMac) {
                pthread_jit_write_protect_np(false);
            }
            _ = TCC.tcc_relocate(state, bytes.ptr);
            if (comptime Environment.isAarch64 and Environment.isMac) {
                pthread_jit_write_protect_np(true);
            }

            var symbol = TCC.tcc_get_symbol(state, "my_callback_function") orelse {
                this.step = .{ .failed = .{ .msg = "missing generated symbol in source code" } };

                return;
            };
            Output.debug("symbol: {*}", .{symbol});
            Output.debug("bun_call: {*}", .{&bun_call});
            Output.debug("js_function: {*}", .{js_function});

            this.step = .{
                .compiled = .{
                    .ptr = symbol,
                    .buf = &[_]u8{},
                    .js_function = js_function,
                    .js_context = js_context,
                },
            };
        }

        pub fn printSourceCode(
            this: *Function,
            writer: anytype,
        ) !void {
            brk: {
                if (this.return_type.isFloatingPoint()) {
                    try writer.writeAll("#define USES_FLOAT 1\n");
                    break :brk;
                }

                for (this.arg_types.items) |arg| {
                    // conditionally include math.h
                    if (arg.isFloatingPoint()) {
                        try writer.writeAll("#define USES_FLOAT 1\n");
                        break;
                    }
                }
            }

            if (comptime Environment.isRelease) {
                try writer.writeAll(std.mem.span(FFI_HEADER));
            } else {
                try writer.writeAll(ffiHeader());
            }

            // -- Generate the FFI function symbol
            try writer.writeAll("/* --- The Function To Call */\n");
            try this.return_type.typename(writer);
            try writer.writeAll(" ");
            try writer.writeAll(std.mem.span(this.base_name));
            try writer.writeAll("(");
            var first = true;
            for (this.arg_types.items) |arg, i| {
                if (!first) {
                    try writer.writeAll(", ");
                }
                first = false;
                try arg.typename(writer);
                try writer.print(" arg{d}", .{i});
            }
            try writer.writeAll(");\n\n");

            // -- Generate JavaScriptCore's C wrapper function
            try writer.writeAll("/* ---- Your Wrapper Function ---- */\nvoid* bun_gen_");
            try writer.writeAll(std.mem.span(this.base_name));
            try writer.writeAll("(JSContext ctx, void* function, void* thisObject, size_t argumentCount, const EncodedJSValue arguments[], void* exception);\n\n");

            try writer.writeAll("void* bun_gen_");
            try writer.writeAll(std.mem.span(this.base_name));
            try writer.writeAll("(JSContext ctx, void* function, void* thisObject, size_t argumentCount, const EncodedJSValue arguments[], void* exception) {\n\n");
            if (comptime Environment.isDebug) {
                try writer.writeAll("#ifdef INJECT_BEFORE\n");
                try writer.writeAll("INJECT_BEFORE;\n");
                try writer.writeAll("#endif\n");
            }
            var arg_buf: [512]u8 = undefined;
            arg_buf[0.."arguments[".len].* = "arguments[".*;
            for (this.arg_types.items) |arg, i| {
                try writer.writeAll("    ");
                try arg.typename(writer);
                var printed = std.fmt.bufPrintIntToSlice(arg_buf["arguments[".len..], i, 10, .lower, .{});
                arg_buf["arguments[".len + printed.len] = ']';
                try writer.print(" arg{d} = {};\n", .{ i, arg.toC(arg_buf[0 .. printed.len + "arguments[]".len]) });
            }

            try writer.writeAll("    ");
            if (!(this.return_type == .void)) {
                try this.return_type.typename(writer);
                try writer.writeAll(" return_value = ");
            }
            try writer.print("{s}(", .{std.mem.span(this.base_name)});
            first = true;
            for (this.arg_types.items) |_, i| {
                if (!first) {
                    try writer.writeAll(", ");
                }
                first = false;
                try writer.print("arg{d}", .{i});
            }
            try writer.writeAll(");\n");
            if (!first) try writer.writeAll("\n");

            try writer.writeAll("    ");

            try writer.writeAll("return ");

            if (!(this.return_type == .void)) {
                try writer.print("{}.asPtr", .{this.return_type.toJS("return_value")});
            } else {
                try writer.writeAll("ValueUndefined.asPtr");
            }

            try writer.writeAll(";\n}\n\n");
        }

        pub fn printCallbackSourceCode(
            this: *Function,
            writer: anytype,
        ) !void {
            try writer.writeAll("#define IS_CALLBACK 1\n");

            brk: {
                if (this.return_type.isFloatingPoint()) {
                    try writer.writeAll("#define USES_FLOAT 1\n");
                    break :brk;
                }

                for (this.arg_types.items) |arg| {
                    // conditionally include math.h
                    if (arg.isFloatingPoint()) {
                        try writer.writeAll("#define USES_FLOAT 1\n");
                        break;
                    }
                }
            }

            if (comptime Environment.isRelease) {
                try writer.writeAll(std.mem.span(FFI_HEADER));
            } else {
                try writer.writeAll(ffiHeader());
            }

            // -- Generate the FFI function symbol
            try writer.writeAll("\n \n/* --- The Callback Function */\n");
            try writer.writeAll("/* --- The Callback Function */\n");
            try this.return_type.typename(writer);
            try writer.writeAll(" my_callback_function");
            try writer.writeAll("(");
            var first = true;
            for (this.arg_types.items) |arg, i| {
                if (!first) {
                    try writer.writeAll(", ");
                }
                first = false;
                try arg.typename(writer);
                try writer.print(" arg{d}", .{i});
            }
            try writer.writeAll(");\n\n");

            try this.return_type.typename(writer);

            try writer.writeAll(" my_callback_function");
            try writer.writeAll("(");
            for (this.arg_types.items) |arg, i| {
                if (!first) {
                    try writer.writeAll(", ");
                }
                first = false;
                try arg.typename(writer);
                try writer.print(" arg{d}", .{i});
            }
            try writer.writeAll(") {\n");

            if (comptime Environment.isDebug) {
                try writer.writeAll("#ifdef INJECT_BEFORE\n");
                try writer.writeAll("INJECT_BEFORE;\n");
                try writer.writeAll("#endif\n");
            }

            first = true;

            if (this.arg_types.items.len > 0) {
                try writer.print("  EncodedJSValue arguments[{d}] = {{\n", .{this.arg_types.items.len});

                var arg_buf: [512]u8 = undefined;
                arg_buf[0.."arg".len].* = "arg".*;
                for (this.arg_types.items) |arg, i| {
                    try arg.typename(writer);
                    const printed = std.fmt.bufPrintIntToSlice(arg_buf["arg".len..], i, 10, .lower, .{});
                    const arg_name = arg_buf[0 .. "arg".len + printed.len];
                    try writer.print("    {}", .{arg.toJS(arg_name)});
                    if (i < this.arg_types.items.len - 1) {
                        try writer.writeAll(",\n");
                    }
                }
                try writer.writeAll("\n  };\n");
            } else {
                try writer.writeAll(" EncodedJSValue arguments[1] = {{0}};\n");
            }

            try writer.writeAll("  ");
            if (!(this.return_type == .void)) {
                try writer.writeAll("  EncodedJSValue return_value = {");
            }
            // JSC.C.JSObjectCallAsFunction(
            //     ctx,
            //     object,
            //     thisObject,
            //     argumentCount,
            //     arguments,
            //     exception,
            // );
            try writer.writeAll("bun_call(cachedJSContext, cachedCallbackFunction, (void*)0, ");
            if (this.arg_types.items.len > 0) {
                try writer.print("{d}, arguments, 0)", .{this.arg_types.items.len});
            } else {
                try writer.writeAll("0, arguments, (void*)0)");
            }

            if (this.return_type != .void) {
                try writer.print("}};\n  return {}", .{this.return_type.toC("return_value")});
            }

            try writer.writeAll(";\n}\n\n");
        }
    };

    pub const ABIType = enum(i32) {
        char = 0,

        int8_t = 1,
        uint8_t = 2,

        int16_t = 3,
        uint16_t = 4,

        int32_t = 5,
        uint32_t = 6,

        int64_t = 7,
        uint64_t = 8,

        double = 9,
        float = 10,

        bool = 11,

        ptr = 12,

        @"void" = 13,

        const map = .{
            .{ "bool", ABIType.bool },
            .{ "c_int", ABIType.int32_t },
            .{ "c_uint", ABIType.uint32_t },
            .{ "char", ABIType.char },
            .{ "char*", ABIType.ptr },
            .{ "double", ABIType.double },
            .{ "f32", ABIType.float },
            .{ "f64", ABIType.double },
            .{ "float", ABIType.float },
            .{ "i16", ABIType.int16_t },
            .{ "i32", ABIType.int32_t },
            .{ "i64", ABIType.int64_t },
            .{ "i8", ABIType.int8_t },
            .{ "int", ABIType.int32_t },
            .{ "int16_t", ABIType.int16_t },
            .{ "int32_t", ABIType.int32_t },
            .{ "int64_t", ABIType.int64_t },
            .{ "int8_t", ABIType.int8_t },
            .{ "isize", ABIType.int64_t },
            .{ "u16", ABIType.uint16_t },
            .{ "u32", ABIType.uint32_t },
            .{ "u64", ABIType.uint64_t },
            .{ "u8", ABIType.uint8_t },
            .{ "uint16_t", ABIType.uint16_t },
            .{ "uint32_t", ABIType.uint32_t },
            .{ "uint64_t", ABIType.uint64_t },
            .{ "uint8_t", ABIType.uint8_t },
            .{ "usize", ABIType.uint64_t },
            .{ "void*", ABIType.ptr },
            .{ "ptr", ABIType.ptr },
            .{ "pointer", ABIType.ptr },
        };
        pub const label = ComptimeStringMap(ABIType, map);
        const EnumMapFormatter = struct {
            name: []const u8,
            entry: ABIType,
            pub fn format(self: EnumMapFormatter, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.writeAll("['");
                // these are not all valid identifiers
                try writer.writeAll(self.name);
                try writer.writeAll("']:");
                try std.fmt.formatInt(@enumToInt(self.entry), 10, .lower, .{}, writer);
                try writer.writeAll(",'");
                try std.fmt.formatInt(@enumToInt(self.entry), 10, .lower, .{}, writer);
                try writer.writeAll("':");
                try std.fmt.formatInt(@enumToInt(self.entry), 10, .lower, .{}, writer);
            }
        };
        pub const map_to_js_object = brk: {
            var count: usize = 2;
            for (map) |item, i| {
                var fmt = EnumMapFormatter{ .name = item.@"0", .entry = item.@"1" };
                count += std.fmt.count("{}", .{fmt});
                count += @boolToInt(i > 0);
            }

            var buf: [count]u8 = undefined;
            buf[0] = '{';
            buf[buf.len - 1] = '}';
            var end: usize = 1;
            for (map) |item, i| {
                var fmt = EnumMapFormatter{ .name = item.@"0", .entry = item.@"1" };
                if (i > 0) {
                    buf[end] = ',';
                    end += 1;
                }
                end += (std.fmt.bufPrint(buf[end..], "{}", .{fmt}) catch unreachable).len;
            }

            break :brk buf;
        };

        pub fn isFloatingPoint(this: ABIType) bool {
            return switch (this) {
                .double, .float => true,
                else => false,
            };
        }

        const ToCFormatter = struct {
            symbol: string,
            tag: ABIType,

            pub fn format(self: ToCFormatter, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                switch (self.tag) {
                    .void => {},
                    .bool => {
                        try writer.print("JSVALUE_TO_BOOL({s})", .{self.symbol});
                    },
                    .char, .int8_t, .uint8_t, .int16_t, .uint16_t, .int32_t, .uint32_t => {
                        try writer.print("JSVALUE_TO_INT32({s})", .{self.symbol});
                    },
                    .int64_t => {},
                    .uint64_t => {},
                    .ptr => {
                        try writer.print("JSVALUE_TO_PTR({s})", .{self.symbol});
                    },
                    .double => {
                        try writer.print("JSVALUE_TO_DOUBLE({s})", .{self.symbol});
                    },
                    .float => {
                        try writer.print("JSVALUE_TO_FLOAT({s})", .{self.symbol});
                    },
                }
            }
        };

        const ToJSFormatter = struct {
            symbol: []const u8,
            tag: ABIType,

            pub fn format(self: ToJSFormatter, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
                switch (self.tag) {
                    .void => {},
                    .bool => {
                        try writer.print("BOOLEAN_TO_JSVALUE({s})", .{self.symbol});
                    },
                    .char, .int8_t, .uint8_t, .int16_t, .uint16_t, .int32_t, .uint32_t => {
                        try writer.print("INT32_TO_JSVALUE({s})", .{self.symbol});
                    },
                    .int64_t => {},
                    .uint64_t => {},
                    .ptr => {
                        try writer.print("PTR_TO_JSVALUE({s})", .{self.symbol});
                    },
                    .double => {
                        try writer.print("DOUBLE_TO_JSVALUE({s})", .{self.symbol});
                    },
                    .float => {
                        try writer.print("FLOAT_TO_JSVALUE({s})", .{self.symbol});
                    },
                }
            }
        };

        pub fn toC(this: ABIType, symbol: string) ToCFormatter {
            return ToCFormatter{ .tag = this, .symbol = symbol };
        }

        pub fn toJS(
            this: ABIType,
            symbol: string,
        ) ToJSFormatter {
            return ToJSFormatter{
                .tag = this,
                .symbol = symbol,
            };
        }

        pub fn typename(this: ABIType, writer: anytype) !void {
            try writer.writeAll(this.typenameLabel());
        }

        pub fn typenameLabel(this: ABIType) []const u8 {
            return switch (this) {
                .ptr => "void*",
                .bool => "bool",
                .int8_t => "int8_t",
                .uint8_t => "uint8_t",
                .int16_t => "int16_t",
                .uint16_t => "uint16_t",
                .int32_t => "int32_t",
                .uint32_t => "uint32_t",
                .int64_t => "int64_t",
                .uint64_t => "uint64_t",
                .double => "double",
                .float => "float",
                .char => "char",
                .void => "void",
            };
        }
    };
};