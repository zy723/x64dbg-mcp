#pragma once
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace MCP {

/**
 * @brief 寄存器方法处理器
 * 实现 register.* 系列 JSON-RPC 方法
 */
class RegisterHandler {
public:
    /**
     * @brief 注册所有寄存器方法到分发器
     */
    static void RegisterMethods();
    
    /**
     * @brief register.get - 读取寄存器值
     */
    static json Get(const json& params);
    
    /**
     * @brief register.set - 设置寄存器值
     */
    static json Set(const json& params);
    
    /**
     * @brief register.list - 列出所有寄存器
     */
    static json List(const json& params);
    
    /**
     * @brief register.get_batch - 批量读取寄存器
     */
    static json GetBatch(const json& params);

    /**
     * @brief register.get_all - 紧凑返回所有 GPR {name: hex_value}
     * 用于高频采样，比 register.list 流量更小
     */
    static json GetAll(const json& params);
};

} // namespace MCP
