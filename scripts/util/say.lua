return function(msg)
    -- 防御：msg 为 nil 会让 ChatHistory:SendCommandResponse 崩在 ipairs(nil)
    -- （见过 STRINGS 表取错导致 Say(nil) 直接崩 HUD 点击链路），静默丢弃。
    if msg == nil then
        return
    end
    if ChatHistory then
        ChatHistory:SendCommandResponse(msg)
    end
end
