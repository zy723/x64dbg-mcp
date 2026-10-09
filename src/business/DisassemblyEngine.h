#pragma once
#include <string>
#include <vector>
#include <cstdint>
#include <optional>

namespace MCP {

/**
 * @brief 反汇编指令信息
 */
struct InstructionInfo {
    uint64_t address;           // 指令地址
    std::vector<uint8_t> bytes; // 指令字节码
    std::string mnemonic;       // 助记符 (如 "mov")
    std::string operands;       // 操作数 (如 "rax, rbx")
    std::string full;           // 完整指令 (如 "mov rax, rbx")
    std::string comment;        // 注释
    size_t size;                // 指令长度
    
    // 扩展信息
    bool isBranch;              // 是否为分支指令
    bool isCall;                // 是否为调用指令
    bool isRet;                 // 是否为返回指令
    std::optional<uint64_t> branchTarget; // 分支目标地址
};

/**
 * @brief 反汇编引擎
 * 封装 x64dbg 的反汇编功能
 */
class DisassemblyEngine {
public:
    /**
     * @brief 获取单例实例
     */
    static DisassemblyEngine& Instance();
    
    /**
     * @brief 反汇编单条指令
     * @param address 指令地址
     * @return 指令信息
     */
    InstructionInfo DisassembleAt(uint64_t address);
    
    /**
     * @brief 反汇编多条指令
     * @param address 起始地址
     * @param count 指令数量
     * @return 指令列表
     */
    std::vector<InstructionInfo> DisassembleRange(uint64_t address, size_t count);
    
    /**
     * @brief 反汇编指定字节数
     * @param address 起始地址
     * @param size 字节数
     * @return 指令列表
     */
    std::vector<InstructionInfo> DisassembleBytes(uint64_t address, size_t size);
    
    /**
     * @brief 反汇编一个函数
     * @param address 函数地址
     * @param maxInstructions 上限（默认 2000；<=0 时不限）
     * @return 指令列表
     */
    std::vector<InstructionInfo> DisassembleFunction(uint64_t address, size_t maxInstructions = 2000);
    
    /**
     * @brief 获取指令长度
     * @param address 指令地址
     * @return 指令长度(字节数)
     */
    size_t GetInstructionLength(uint64_t address);
    
    /**
     * @brief 获取下一条指令地址
     * @param address 当前指令地址
     * @return 下一条指令地址
     */
    uint64_t GetNextInstruction(uint64_t address);
    
    /**
     * @brief 获取上一条指令地址
     * @param address 当前指令地址
     * @return 上一条指令地址
     */
    uint64_t GetPreviousInstruction(uint64_t address);
    
    /**
     * @brief 检查是否为有效指令
     * @param address 地址
     * @return 是否有效
     */
    bool IsValidInstruction(uint64_t address);
    
    /**
     * @brief 格式化指令为字符串
     * @param info 指令信息
     * @param includeBytes 是否包含字节码
     * @param includeAddress 是否包含地址
     * @return 格式化的字符串
     */
    std::string FormatInstruction(const InstructionInfo& info, 
                                  bool includeBytes = true,
                                  bool includeAddress = true);

private:
    DisassemblyEngine() = default;
    ~DisassemblyEngine() = default;
    DisassemblyEngine(const DisassemblyEngine&) = delete;
    DisassemblyEngine& operator=(const DisassemblyEngine&) = delete;
    
    void AnalyzeInstruction(InstructionInfo& info);
    bool IsBranchInstruction(const std::string& mnemonic);
    bool IsCallInstruction(const std::string& mnemonic);
    bool IsRetInstruction(const std::string& mnemonic);
    std::optional<uint64_t> ExtractBranchTarget(const InstructionInfo& info);
};

} // namespace MCP
