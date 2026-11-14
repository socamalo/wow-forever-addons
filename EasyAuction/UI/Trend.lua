local addonName, ns = ... -- luacheck: ignore addonName
local CreateFrame, GameTooltip, GetMoneyString, date = CreateFrame, GameTooltip, GetMoneyString, date
local ipairs, tostring, unpack = ipairs, tostring, unpack
local min, max, floor, huge = math.min, math.max, math.floor, math.huge
local L = ns.L
local Trend = {}; ns.TrendPlot = Trend
local C = ns.Widgets and ns.Widgets.color or {accent={0.39,0.85,0.70},gold={0.96,0.79,0.35}}

local function Tooltip(node)
    local point=node.point
    if not point then return end
    GameTooltip:SetOwner(node,"ANCHOR_RIGHT")
    local daily=point.period=="day"
    GameTooltip:SetText(date(daily and "%m/%d" or "%m/%d %H:%M",point.time)..(node.latest and L[" · 最新"] or ""))
    GameTooltip:AddDoubleLine(daily and L["当日末次最低价"] or L["小时末次最低价"],
        GetMoneyString(floor(point.price),true),0.65,0.72,0.72,1,1,1)
    GameTooltip:AddDoubleLine(L["在售"],tostring(point.quantity or 0),0.65,0.72,0.72,1,1,1)
    GameTooltip:Show()
end

local function AcquireNode(plot,index)
    local node=plot.trendNodes[index]
    if node then return node end
    node=CreateFrame("Button",nil,plot)
    node:SetSize(10,10)
    node.dot=node:CreateTexture(nil,"OVERLAY")
    node.dot:SetPoint("CENTER")
    node:SetScript("OnEnter",Tooltip)
    node:SetScript("OnLeave",function() GameTooltip:Hide() end)
    node:SetScript("OnHide",function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    plot.trendNodes[index]=node
    return node
end

-- Points are chronological observations at the requested hour/day granularity.
function Trend.Render(plot,points,first,ending)
    plot.trendNodes=plot.trendNodes or {}
    plot.trendLines=plot.trendLines or {}
    for index,node in ipairs(plot.trendNodes) do node:Hide(); node.point=nil end
    for index,line in ipairs(plot.trendLines) do line:Hide() end
    if #points==0 then return nil,nil end
    local low,high=huge,-huge
    for index,point in ipairs(points) do low=min(low,point.price); high=max(high,point.price) end
    local width,height=max(0,plot:GetWidth()),max(0,plot:GetHeight())
    local duration=max(1,ending-first)
    local previousX,previousY
    for index,point in ipairs(points) do
        local x=max(0,min(width,(point.time-first)/duration*width))
        local y=high==low and height/2 or (point.price-low)/(high-low)*height
        local node=AcquireNode(plot,index)
        node.point=point; node.latest=index==#points
        node:ClearAllPoints(); node:SetPoint("CENTER",plot,"BOTTOMLEFT",x,y)
        node:SetFrameLevel(plot:GetFrameLevel()+(node.latest and 3 or 2))
        node.dot:SetSize(node.latest and 8 or 4,node.latest and 8 or 4)
        node.dot:SetColorTexture(unpack(node.latest and C.gold or C.accent)); node:Show()
        if previousX then
            local line=plot.trendLines[index-1]
            if not line then line=plot:CreateLine(nil,"ARTWORK"); plot.trendLines[index-1]=line end
            line:SetColorTexture(unpack(C.accent)); line:SetThickness(1.5)
            line:SetStartPoint("BOTTOMLEFT",plot,previousX,previousY)
            line:SetEndPoint("BOTTOMLEFT",plot,x,y); line:Show()
        end
        previousX,previousY=x,y
    end
    return low,high
end
