#include "DebugHandler.h"
#include "../business/DebugController.h"
#include "../core/ArchitectureRegisterNames.h"
#include "../core/MethodDispatcher.h"
#include "../core/RequestValidator.h"
#include "../core/Logger.h"
#include "../core/X64DBGBridge.h"
#include "../utils/StringUtils.h"
#include <windows.h>
#include <cstdlib>
#include <chrono>
#include <limits>
#include <thread>

namespace MCP {

void DebugHandler::RegisterMethods() {
    auto& dispatcher = MethodDispatcher::Instance();
    
    dispatcher.RegisterMethod("debug.get_state", GetState);
    dispatcher.RegisterMethod("debug.run", Run);
    dispatcher.RegisterMethod("debug.pause", Pause);
    dispatcher.RegisterMethod("debug.step_into", StepInto);
    dispatcher.RegisterMethod("debug.step_over", StepOver);
    dispatcher.RegisterMethod("debug.step_out", StepOut);
    dispatcher.RegisterMethod("debug.run_to", RunTo);
    dispatcher.RegisterMethod("debug.restart", Restart);
    dispatcher.RegisterMethod("debug.init", Init);
    dispatcher.RegisterMethod("debug.attach_pid", AttachPid);
    dispatcher.RegisterMethod("debug.detach", Detach);
    dispatcher.RegisterMethod("debug.get_pid", GetPid);
    dispatcher.RegisterMethod("debug.get_exit_code", GetExitCode);
    dispatcher.RegisterMethod("debug.run_until_break", RunUntilBreak);
    dispatcher.RegisterMethod("debug.stop", Stop);
    
    Logger::Info("Registered debug.* methods");
}

json DebugHandler::GetState(const json& params) {
    auto& controller = DebugController::Instance();
    
    DebugState state = controller.GetState();
    std::string stateStr = StateToString(state);
    
    json result = {
        {"state", stateStr}
    };
    
    if (controller.IsDebugging()) {
        try {
            uint64_t rip = controller.GetInstructionPointer();
            result[ArchitectureRegisterNames::InstructionPointer] = StringUtils::FormatAddress(rip);
        } catch (...) {
            // 如果无法获取 RIP，忽略错误
        }
    }
    
    return result;
}

json DebugHandler::Run(const json& params) {
    auto& controller = DebugController::Instance();
    
    bool success = controller.Run();
    
    json result = {
        {"success", success}
    };
    
    // 等待一小段时间让调试器状态稳定
    Sleep(50);
    
    // 获取当前状态
    DebugState state = controller.GetState();
    result["state"] = StateToString(state);
    
    // 如果暂停了，返回停止原因
    if (controller.IsPaused()) {
        try {
            uint64_t rip = controller.GetInstructionPointer();
            result[ArchitectureRegisterNames::InstructionPointer] = StringUtils::FormatAddress(rip);
            result["stop_reason"] = "breakpoint_or_exception";
        } catch (...) {
            // 忽略
        }
    }
    
    return result;
}

json DebugHandler::Pause(const json& params) {
    auto& controller = DebugController::Instance();
    
    bool success = controller.Pause();
    uint64_t rip = 0;
    
    if (success && controller.IsPaused()) {
        try {
            rip = controller.GetInstructionPointer();
        } catch (...) {
            // 忽略
        }
    }
    
    json result = {
        {"success", success}
    };
    
    if (rip != 0) {
        result[ArchitectureRegisterNames::InstructionPointer] = StringUtils::FormatAddress(rip);
    }
    
    return result;
}

json DebugHandler::StepInto(const json& params) {
    auto& controller = DebugController::Instance();
    
    uint64_t rip = controller.StepInto();
    
    return {
        {ArchitectureRegisterNames::InstructionPointer, StringUtils::FormatAddress(rip)}
    };
}

json DebugHandler::StepOver(const json& params) {
    auto& controller = DebugController::Instance();
    
    uint64_t rip = controller.StepOver();
    
    return {
        {ArchitectureRegisterNames::InstructionPointer, StringUtils::FormatAddress(rip)}
    };
}

json DebugHandler::StepOut(const json& params) {
    auto& controller = DebugController::Instance();
    
    uint64_t rip = controller.StepOut();
    
    return {
        {ArchitectureRegisterNames::InstructionPointer, StringUtils::FormatAddress(rip)}
    };
}

json DebugHandler::RunTo(const json& params) {
    uint64_t address = RequestValidator::GetAddress(params, "address");
    
    auto& controller = DebugController::Instance();
    bool success = controller.RunToAddress(address);
    
    return {
        {"success", success},
        {"address", StringUtils::FormatAddress(address)}
    };
}

json DebugHandler::Restart(const json& params) {
    auto& controller = DebugController::Instance();
    
    bool success = controller.Restart();
    
    return {
        {"success", success}
    };
}

json DebugHandler::Init(const json& params) {
    auto& controller = DebugController::Instance();

    std::string path = RequestValidator::GetString(params, "path", "");
    std::string arguments = RequestValidator::GetString(params, "arguments", "");
    std::string currentDir = RequestValidator::GetString(params, "current_dir", "");

    // Validate that path/arguments/currentDir do not contain x64dbg command
    // separators (commas break argument parsing inside the init command).
    auto containsDangerousSep = [](const std::string& s) {
        return s.find(',') != std::string::npos;
    };
    if (containsDangerousSep(path)) {
        return {{"success", false}, {"error", "Path must not contain commas"}};
    }
    if (containsDangerousSep(arguments)) {
        return {{"success", false}, {"error", "Arguments must not contain commas"}};
    }
    if (containsDangerousSep(currentDir)) {
        return {{"success", false}, {"error", "Current directory must not contain commas"}};
    }

    if (path.empty()) {
        // Fall back to the cached path from a previous session.
        path = controller.GetLastDebuggedPath();
    }

    if (path.empty()) {
        return {
            {"success", false},
            {"error", "No executable path provided and no previously debugged target cached"}
        };
    }

    bool success = controller.Init(path, arguments, currentDir);

    json result = {
        {"success", success},
        {"path", path}
    };

    if (!arguments.empty()) {
        result["arguments"] = arguments;
    }
    if (!currentDir.empty()) {
        result["current_dir"] = currentDir;
    }

    return result;
}

json DebugHandler::AttachPid(const json& params) {
    if (!params.contains("pid")) {
        return {
            {"success", false},
            {"error", "Missing required parameter 'pid'"}
        };
    }

    uint32_t pid = 0;
    try {
        if (params["pid"].is_number_unsigned()) {
            pid = params["pid"].get<uint32_t>();
        } else if (params["pid"].is_number_integer()) {
            const int64_t value = params["pid"].get<int64_t>();
            if (value <= 0) {
                return {{"success", false}, {"error", "pid must be positive"}};
            }
            pid = static_cast<uint32_t>(value);
        } else if (params["pid"].is_string()) {
            const std::string text = params["pid"].get<std::string>();
            const size_t start = text.find_first_not_of(" \t");
            const size_t end = text.find_last_not_of(" \t");
            if (start == std::string::npos) {
                return {{"success", false}, {"error", "pid string is empty"}};
            }
            const std::string trimmed = text.substr(start, end - start + 1);
            const unsigned long parsed = std::strtoul(trimmed.c_str(), nullptr, 10);
            if (parsed == 0 || parsed > std::numeric_limits<uint32_t>::max()) {
                return {{"success", false}, {"error", "invalid pid string"}};
            }
            pid = static_cast<uint32_t>(parsed);
        } else {
            return {{"success", false}, {"error", "pid must be number or string"}};
        }
    } catch (const std::exception& e) {
        return {{"success", false}, {"error", e.what()}};
    }

    bool useAttachBreak = RequestValidator::GetBoolean(params, "attach_break", false);
    bool detachFirst = RequestValidator::GetBoolean(params, "detach_first", true);
    const int64_t timeoutMs = RequestValidator::GetInteger(params, "timeout_ms", 15000);

    auto& controller = DebugController::Instance();
    const bool success = controller.AttachProcess(
        pid,
        static_cast<uint32_t>(timeoutMs > 0 ? timeoutMs : 15000),
        useAttachBreak,
        detachFirst
    );

    json result = {
        {"success", success},
        {"requested_pid", pid},
        {"debugging", controller.IsDebugging()}
    };

    if (success) {
        result["state"] = StateToString(controller.GetState());
        const uint32_t attachedPid = controller.GetDebuggeeProcessId();
        if (attachedPid != 0) {
            result["attached_pid"] = attachedPid;
        }
        if (controller.IsDebugging()) {
            try {
                result[ArchitectureRegisterNames::InstructionPointer] = StringUtils::FormatAddress(controller.GetInstructionPointer());
            } catch (...) {
            }
        }
    } else {
        result["error"] = std::string("attach failed (see ") + PLUGIN_DIR_NAME + ".log)";
    }

    return result;
}

json DebugHandler::Detach(const json& params) {
    auto& controller = DebugController::Instance();
    const int64_t timeoutMs = RequestValidator::GetInteger(params, "timeout_ms", 5000);
    const bool success = controller.Detach(static_cast<uint32_t>(timeoutMs > 0 ? timeoutMs : 5000));
    return {
        {"success", success},
        {"debugging", controller.IsDebugging()}
    };
}

json DebugHandler::GetPid(const json& params) {
    auto& controller = DebugController::Instance();
    const uint32_t pid = controller.GetDebuggeeProcessId();
    json result = {
        {"debugging", controller.IsDebugging()},
        {"pid", pid}
    };

#ifdef XDBG_SDK_AVAILABLE
    // Also report process handle-derived PID as a sanity cross-check
    HANDLE hProc = DbgGetProcessHandle();
    if (hProc != nullptr && hProc != INVALID_HANDLE_VALUE) {
        const DWORD handlePid = GetProcessId(hProc);
        if (handlePid != 0) {
            result["pid_from_handle"] = static_cast<uint32_t>(handlePid);
            if (pid != 0 && handlePid != pid) {
                result["pid_mismatch"] = true;
            }
        }
    }
#endif
    return result;
}

json DebugHandler::GetExitCode(const json& params) {
    auto& controller = DebugController::Instance();
    const bool debugging = controller.IsDebugging();
    json result = {{"debugging", debugging}};
    if (!debugging) {
        result["exited"] = false;
        return result;
    }
    uint32_t exitCode = 0;
    if (controller.GetDebuggeeExitCode(exitCode)) {
        result["exited"] = true;
        result["exit_code"] = exitCode;
        result["exit_code_hex"] = StringUtils::FormatAddress(exitCode);
    } else {
        result["exited"] = false;
    }
    return result;
}

json DebugHandler::RunUntilBreak(const json& params) {
    auto& controller = DebugController::Instance();
    const int64_t timeoutMs = RequestValidator::GetInteger(params, "timeout_ms", 15000);
    const int64_t clamped = timeoutMs > 120000 ? 120000 : (timeoutMs > 0 ? timeoutMs : 15000);

    if (!controller.IsDebugging()) {
        return {{"success", false}, {"error", "debugger not running"}};
    }

    // Kick off execution
    if (!controller.Run()) {
        return {{"success", false}, {"error", "run command failed"}};
    }

    // Poll state until paused / process exits / timeout
    auto start = std::chrono::steady_clock::now();
    while (true) {
        // pump GUI messages so x64dbg command queue is processed
        // (Pause/Wait already pumps internally; here we inline)
        Sleep(20);

        DebugState state = controller.GetState();
        if (state == DebugState::Paused) {
            try {
                const uint64_t rip = controller.GetInstructionPointer();
                return {
                    {"success", true},
                    {"state", "paused"},
                    {"reason", "breakpoint_or_exception"},
                    {ArchitectureRegisterNames::InstructionPointer, StringUtils::FormatAddress(rip)}
                };
            } catch (...) {
                return {{"success", true}, {"state", "paused"}};
            }
        }
        if (state == DebugState::Stopped) {
            return {
                {"success", false},
                {"state", "stopped"},
                {"reason", "process_exited_or_detached"}
            };
        }

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start).count();
        if (elapsed >= clamped) {
            return {
                {"success", false},
                {"state", StateToString(state)},
                {"reason", "timeout"},
                {"elapsed_ms", static_cast<long long>(elapsed)}
            };
        }
    }
}

json DebugHandler::Stop(const json& params) {
    auto& controller = DebugController::Instance();
    
    bool success = controller.Stop();
    
    return {
        {"success", success}
    };
}

std::string DebugHandler::StateToString(DebugState state) {
    switch (state) {
        case DebugState::Stopped:
            return "stopped";
        case DebugState::Running:
            return "running";
        case DebugState::Paused:
            return "paused";
        default:
            return "unknown";
    }
}

} // namespace MCP
