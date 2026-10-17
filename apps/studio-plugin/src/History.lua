--!strict
-- Native Studio undo/redo boundary for bridge mutations.

local ChangeHistoryService=game:GetService("ChangeHistoryService")

local History={}

function History.record(name:string,fn:()->any):any
    local identifier=ChangeHistoryService:TryBeginRecording(name,name)
    if not identifier then
        error("ChangeHistoryService refused to begin recording: "..name,0)
    end

    local packed
    local ok,err=pcall(function()
        packed=table.pack(fn())
    end)

    local finishOk,finishErr=pcall(function()
        ChangeHistoryService:FinishRecording(
            identifier,
            ok and Enum.FinishRecordingOperation.Commit
                or Enum.FinishRecordingOperation.Cancel
        )
    end)

    if not ok then
        error(err,0)
    end
    if not finishOk then
        error("ChangeHistoryService failed to finish recording: "..tostring(finishErr),0)
    end

    return table.unpack(packed,1,packed.n)
end

return History
