local use_max_distance = 400

local ceil = math.ceil
local clamp = math.Clamp
local pi = math.pi
local sqrt = math.sqrt
local curtime = CurTime
local IsValid = IsValid
--local realFrameTime = RealFrameTime

if SERVER then
    util.AddNetworkString("march.seatxray.request_use")

    net.Receive("march.seatxray.request_use", function(_, ply)
        local requested_entity = net.ReadEntity()

        if not IsValid(requested_entity) then return end            -- can't be invalid
        if not requested_entity:IsVehicle() then return end         -- needs to be a vehicle
        if requested_entity:CPPIGetOwner() ~= ply then return end   -- and needs to be owned by the player sending the net message
        if requested_entity:GetPos():Distance(ply:EyePos()) > use_max_distance then return end -- checks the distance
        -- all other checks aren't necessary here

        local can_enter = hook.Run("CanPlayerEnterVehicle", ply, requested_entity, 1)
        if can_enter == false then return end

        requested_entity:Use(ply, ply, 1)
        if not ply:InVehicle() then -- some seats might not let the player in just from simply a Use call, so this makes 100% sure that it goes through
            ply:EnterVehicle(requested_entity)
        end
    end)
end

if CLIENT then
    local function AnimationSmoother(f, z, r, _xInit)
        local obj = {}

        obj.k1 = z / (pi * f)
        obj.k2 = 1 / ((2 * pi * f) * (2 * pi * f))
        obj.k3 = r * z / (2 * pi * f)
        obj.tcrit = 0.8 * (sqrt(4 * obj.k2  + obj.k1 * obj.k1) - obj.k1)

        obj.xp = _xInit
        obj.y = _xInit
        obj.yd = 0

        obj.lastupdate = curtime()

        local tolerance = 0.0001
        function obj:update(x, xd)
            local now = curtime()

            -- tolerance check
            if self.y - tolerance <= x and x <= self.y + tolerance then
                self.lastupdate = now
                return self.y
            end

            -- clamped to avoid extreme delta-time updates from causing too much movement
            local t = clamp(now - self.lastupdate, 0, 0.05)

            -- don't need to run it all again if deltatime is 0
            if t == 0 then
                return self.y
            end

            -- i have no idea what the rest of this does
            if xd == nil then
                xd = (x - self.xp)
                self.xp = x
            end

            local iterations = ceil(t / self.tcrit)
            t = t / iterations

            for i = 0, iterations do
                self.y = self.y + t * self.yd
                self.yd = self.yd + t * (x + self.k3 * xd - self.y - self.k1 * self.yd) / self.k2
            end

            self.lastupdate = now

            return self.y
        end

        return obj
    end

    local seatxray_enable  = CreateConVar("seatxray_enable",  1, FCVAR_ARCHIVE, "Enables/disables all seat xray functionality. This includes both behavior & visuals.")
    local seatxray_showhud = CreateConVar("seatxray_showhud", 1, FCVAR_ARCHIVE, "Enables/disables the prompt that comes up when a seat is detected.")
    local seatxray_show_promptremove_hint = CreateConVar("seatxray_show_promptremove_hint", 1, FCVAR_ARCHIVE, "Removes the prompt to type seatxray_showhud 0 in console after a few seconds.")
    local seatxray_opacity_visible = CreateConVar("seatxray_opacity_visible", 0.1, FCVAR_ARCHIVE, "Changes how transparent/opaque seats are when x-rayed and not hovered.")
    local seatxray_opacity_hovered = CreateConVar("seatxray_opacity_hovered", 0.2, FCVAR_ARCHIVE, "Changes how transparent/opaque seats are when x-rayed and hovered.")
    local seatxray_flicker_rate = CreateConVar("seatxray_flicker_rate", 1, FCVAR_ARCHIVE, "Changes the rate, in seconds, in which a vehicle will flicker when hovered.")
    local seatxray_flicker_intensity = CreateConVar("seatxray_flicker_intensity", 0.1, FCVAR_ARCHIVE, "Changes the intensity of the vehicles flickering when hovered.\nThis adds onto seatxray_opacity_hovered.")

    -- checks if something is blocking line-of-sight to v (an entity). Returns true if somethings in the way
    local function isSomethingInTheWay(v)
        local t = util.TraceLine({start = LocalPlayer():GetShootPos(), endpos = v:GetPos(), filter = v, ignoreworld = true})
        return t.Hit
    end

    -- gets all seats within use_max_distance's radius
    -- the seats must be owned by the localplayer and something must be in the way for the seat to be added
    local function getSeats()
        local eyepos = LocalPlayer():EyePos()
        local ents = ents.FindInSphere(eyepos, use_max_distance)
        local seats = {}

        for _, v in ipairs(ents) do
            if IsValid(v) and v:IsVehicle() and v:CPPIGetOwner() == LocalPlayer() and isSomethingInTheWay(v) then
                seats[#seats + 1] = v
            end
        end

        return seats
    end

    -- finds all entities the player is looking at, from the eyepos to use_max_distance, then returns sorted from closest to furthest
    local function xrayEntitiesAlongEyetrace()
        local eyetrace = LocalPlayer():GetEyeTrace()
        local nrml = (eyetrace.HitPos - eyetrace.StartPos):GetNormalized()

        local hits = ents.FindAlongRay(eyetrace.StartPos, eyetrace.StartPos + (nrml * use_max_distance))

        table.sort(hits, function(a, b)
            return b:GetPos():Distance(eyetrace.StartPos) > a:GetPos():Distance(eyetrace.StartPos)
        end)

        return hits
    end

    -- finds the nearest seat that the player is looking at.
    local function findNearestLookatSeat()
        local hits = xrayEntitiesAlongEyetrace()
        if #hits <= 1 then return nil end -- do nothing when nothing is present or only one entity is present

        for i = 1, #hits do
            local v = hits[i]
            if v:IsVehicle() and isSomethingInTheWay(v) then
                return v
            end
        end

        return nil
    end

    local seats = {}
    local lookat = nil

    local function isSeatXrayEnabled()
        if not seatxray_enable:GetBool() then return false end
        if hook.Run("march.seatxray.block_all") == true then return false end

        return true
    end

    local function shouldUseKeyWork()
        if hook.Run("march.seatxray.block_use") == true then return false end
        local ply = LocalPlayer()
        if ply:KeyDown(IN_ATTACK) or ply:KeyDown(IN_ATTACK2) then return false end

        return true
    end

    timer.Create("march.seatxray.update", 1 / 10, 0, function()
        if not IsValid(LocalPlayer()) then return end -- prevents error where localplayer isn't initialized so getSeats complains
        seats = {}
        lookat = nil

        if not isSeatXrayEnabled() then return end

        seats = getSeats()
        lookat = findNearestLookatSeat()
    end)

    local function drawSeatHighlight(seat, is_looked_at)
        if not IsValid(seat) then return end

        render.DepthRange(0, 0)
        local b = 25525 -- make it crazy bright super simply
        if is_looked_at then
            local a = math.sin(CurTime() * math.pi * 2 * seatxray_flicker_rate:GetFloat()) * seatxray_flicker_intensity:GetFloat()
            render.SetBlend(seatxray_opacity_hovered:GetFloat() + a)
        else
            render.SetBlend(seatxray_opacity_visible:GetFloat() )
        end
        render.SetColorModulation(b,b,b)

        seat:DrawModel()
        render.SetBlend(1)
        render.SetColorModulation(1,1,1)
        render.DepthRange(0, 1)
    end

    local function center(x, y, w, h, ...)
        return x - (w / 2), y - (h / 2), w, h, ...
    end

    local function seatUIRenderer(show_promptremove_hint)
        show_promptremove_hint = show_promptremove_hint == nil and true or show_promptremove_hint
        local f, z, r = 3.02, 1, 0.29
        local window_opacity, window_width, window_height = AnimationSmoother(f,z,r,0), AnimationSmoother(f,z,r,0), AnimationSmoother(f,z,r,0)
        local extra_text_movement, extra_text_opacity = AnimationSmoother(f,z,r,0), AnimationSmoother(f,z,r,0)
        local text, vtext = "", ""
        local lastToggle = 0

        local function renderer(scrw, scrh, seats, lookat)
            if window_opacity.y <= 0.01 and #seats == 0 then lastToggle = 0 return end

            local a, w, h = 0, 0, 0, 0, 0

            if IsValid(lookat) then
                if shouldUseKeyWork() then
                    vtext = "Press [" .. string.upper(input.LookupBinding("+use")) .. "] to enter vehicle #" .. lookat:EntIndex()
                else
                    vtext = "Cannot enter seat while mouse is down."
                end
            else
                vtext = "                         "
            end

            if #seats == 0 then
                w = window_width:update(0)
                h = window_height:update(0)
                a = window_opacity:update(0)
            else
                surface.SetFont("DermaDefault")
                local vtw = surface.GetTextSize(vtext)
                w = window_width:update(vtw + 22)
                h = window_height:update(vtext[1] == " " and 26 or 44)
                a = window_opacity:update(1)
                if lastToggle == 0 then
                    lastToggle = CurTime()
                end
                text = #seats .. " seat" .. (#seats == 1 and "" or "s") .. " available"
            end

            local wd2, hd2 = scrw / 2, scrh / 2

            surface.SetDrawColor(10, 15, 20, 177 * a)
            surface.DrawRect(center(wd2, hd2 + 66, w, h))
            surface.SetDrawColor(220, 230, 255, 255 * a)
            surface.DrawOutlinedRect(center(wd2, hd2 + 66, w, h, 1))

            local xM, xA
            if IsValid(lookat) then
                xM = extra_text_movement:update(8)
                xA = extra_text_opacity:update(1)
            else
                xM = extra_text_movement:update(0)
                xA = extra_text_opacity:update(0)
            end

            draw.SimpleText(text, "DermaDefault", wd2, (hd2 + 64) - xM, Color(220, 230, 255, 255 * a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            draw.SimpleText(vtext, "DermaDefault", wd2, (hd2 + 64) + xM, Color(220, 230, 255, 255 * xA), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

            local drawtextalpha2 = (math.Clamp(CurTime() - lastToggle, 4, 6) - 4) / 2
            if show_promptremove_hint and seatxray_show_promptremove_hint:GetBool() then
                draw.SimpleText("(want to remove this prompt? type seatxray_showhud 0 in console.)", "DermaDefault", wd2, (hd2 + 64) + 32, Color(255, 255, 255, 255 * a * drawtextalpha2), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end

        return renderer
    end

    hook.Add("PreDrawEffects", "march.seatxray.render3D", function()
        if not isSeatXrayEnabled() then return end
        if LocalPlayer():InVehicle() then return end

        render.DepthRange(0, 0)
        for _, seat in ipairs(seats) do
            drawSeatHighlight(seat, seat == lookat)
        end

        render.SetBlend(1)
        render.SetColorModulation(1,1,1)
        render.DepthRange(0, 1)
    end)

    local mainRenderer = seatUIRenderer()
    hook.Add("HUDPaint", "march.seatxray.render2D", function()
        if not isSeatXrayEnabled() then return end
        if not seatxray_showhud:GetBool() then lastToggle = 0 return end
        if LocalPlayer():InVehicle() then lastToggle = 0 return end

        mainRenderer(ScrW(), ScrH(), seats, lookat)
    end)

    hook.Add("KeyPress", "march.seatxray.use_hook", function(_, key)
        if not isSeatXrayEnabled() then return end
        if not shouldUseKeyWork() then return end
        if key == IN_USE and IsFirstTimePredicted() and not LocalPlayer():InVehicle() then
            local seat = findNearestLookatSeat()
            if seat == nil then return end

            net.Start("march.seatxray.request_use")
            net.WriteEntity(seat)
            net.SendToServer()
            lastToggle = 0
        end
    end)

    local function DrawLine(sx, sy, ex, ey, size, fraction)
        fraction = fraction == nil and 1 or math.Clamp(fraction, 0, 1)
        ex, ey = Lerp(fraction, sx, ex), Lerp(fraction, sy, ey)

        local cx = (sx + ex) / 2
        local cy = (sy + ey) / 2

        local w = math.sqrt( (ex-sx) ^ 2 + (ey-sy) ^ 2 )
        local angle = math.deg(math.atan2(sy-ey,ex-sx))
        draw.NoTexture()
        surface.DrawTexturedRectRotated(cx, cy, w, size, angle)
    end

    surface.CreateFont("SeatXRay.LargeHeader", {
        font = "Tahoma",
        size = 20
    })
    surface.CreateFont("SeatXRay.Text", {
        font = "Tahoma",
        size = 13
    })

    local frame
    local function openPreferences()
        if IsValid(frame) then return end

        frame = vgui.Create("DFrame")
        frame:SetSize(1000, 600)
        frame:Center()
        frame:MakePopup()
        frame:SetTitle("Visual Seat X-Ray Preferences Editor (WIP!!!)")

        local function box(x,y,w,h)
            surface.SetDrawColor(10, 15, 20, 240)
            surface.DrawRect(x, y, w, h)
            surface.SetDrawColor(200, 210, 230, 240)
            surface.DrawOutlinedRect(x, y, w, h, 1)
        end

        local renderMock2D, renderMock3D, uiRenderer

        function frame:Paint(w, h)
            box(0, 0, w, 24)
        end

        function frame:OnRemove()
            self.csent2:Remove()
        end

        frame.csent2 = ClientsideModel("models/props_lab/blastdoor001b.mdl")
        local p = 42
        frame.csent2:SetPos(Vector(p, p, 0))
        frame.csent2:SetAngles(Angle(0, 55, 0))
        frame.csent2:SetModelScale(1)
        frame.csent2:Spawn()

        local LeftPanel  = frame:Add("DPanel")
        LeftPanel:DockPadding(4,4,4,4)
        local RightPanel = frame:Add("DScrollPanel")
        RightPanel:DockPadding(4,4,4,4)

        function LeftPanel:Paint(w, h)
            box(0, 0, w, h)
        end
        function RightPanel:Paint(w, h)
            box(0, 0, w, h)
        end

        local function ConvarEditor(name, convar)
            local convarObj = GetConVar(convar)

            local pnl = RightPanel:Add("DPanel")
            pnl:Dock(TOP)
            pnl:SetSize(0, 48)
            pnl:DockPadding(4,4,4,4)
            pnl.Paint = function() end

            local TextPanel, ContentPanel = pnl:Add("DPanel"), pnl:Add("DPanel")
            TextPanel.Paint = function() end
            ContentPanel.Paint = function() end

            ContentPanel:Dock(RIGHT)
            ContentPanel:SetSize(40, 0)
            ContentPanel:DockPadding(8,8,8,8)
            TextPanel:Dock(FILL)
            TextPanel:DockPadding(4,4,4,4)

            local title = TextPanel:Add("DLabel")
            title:Dock(TOP)
            title:SetText(name)
            title:SetContentAlignment(7)
            title:DockMargin(0,-4,-4,-4)
            title:SetFont("SeatXRay.LargeHeader")

            local desc = TextPanel:Add("DLabel")
            desc:Dock(TOP)
            desc:SetText(convarObj:GetHelpText())
            desc:SetContentAlignment(7)
            desc:DockMargin(4,7,0,0)
            desc:SetFont("SeatXRay.Text")

            ContentPanel.Convar = convarObj
            return ContentPanel, pnl
        end

        local function CheckboxConvar(name, convar)
            local contentPanel = ConvarEditor(name, convar)
            local checkBox = contentPanel:Add("DCheckBox")
            checkBox:Dock(FILL)
            checkBox:SetConVar(convar)
            checkBox.animationState = AnimationSmoother(1, 0.6, 0, contentPanel.Convar:GetBool() and 1 or 0)
            function checkBox:Paint(w, h)
                box(0, 0, w, h)
                self.animationState:update(self:GetChecked() and 1 or 0)
                if self.animationState.y >= 0 then
                    DrawLine(2, h / 2, w * 0.4, h - 2, 2, self.animationState.y * 2)
                    DrawLine(w * 0.4, h - 2, w - 2, 4, 2, (self.animationState.y - 0.5) * 2)
                end
            end
        end

        local function NumericalConvar(name, convar, min, max, updates2D)
            updates2D = updates2D or false
            local contentPanel, basePanel = ConvarEditor(name, convar)
            local convarObj = GetConVar(convar)

            local numSlider = RightPanel:Add("DNumSlider")
            numSlider:Dock(TOP)
            numSlider:SetSize(0, 32)
            numSlider:SetText("")
            numSlider:SetMin(min or 0)
            numSlider:SetMax(max or 1)
            numSlider:SetDecimals(2)
            numSlider:SetConVar(convar)

            if updates2D then
                function numSlider:OnValueChanged(val)
                    uiRenderer = seatUIRenderer()
                end
            end
        end

        CheckboxConvar("Enable Seat X-Ray", "seatxray_enable")
        CheckboxConvar("Show HUD Prompt", "seatxray_showhud")
        CheckboxConvar("Show Removal Prompt", "seatxray_show_promptremove_hint")

        NumericalConvar("Opacity While Visible", "seatxray_opacity_visible", 0, 1)
        NumericalConvar("Opacity While Hovered", "seatxray_opacity_hovered", 0, 1)
        NumericalConvar("Flicker Rate", "seatxray_flicker_rate", 0.125, 10)
        NumericalConvar("Flicker Intensity", "seatxray_flicker_intensity", 0, 1)

        local box_hovering = LeftPanel:Add("DCheckBoxLabel")
        box_hovering:SetText("Emulate hovering over the seat")
        box_hovering:SetValue(true)
        box_hovering:Dock(BOTTOM)

        local box_moveaway = LeftPanel:Add("DCheckBoxLabel")
        box_moveaway:SetText("Emulate being close enough to see seats through entities")
        box_moveaway:SetValue(true)
        box_moveaway:Dock(BOTTOM)

        local mover, hoverer = AnimationSmoother(1.4, 1, 0.29, 222), AnimationSmoother(1.4, 1, 0.29, 0)

        local div = frame:Add("DHorizontalDivider")
        div:Dock(FILL)
        div:SetLeft(LeftPanel)
        div:SetRight(RightPanel)
        div:SetDividerWidth(4)
        div:SetLeftMin(500)
        div:SetRightMin(400)
        div:SetLeftWidth(50)

        renderMock3D = LeftPanel:Add("DModelPanel")
        renderMock3D:Dock(FILL)
        renderMock3D:SetModel( "models/props_combine/breenchair.mdl" ) -- you can only change colors on playermodels
        renderMock3D:SetFOV(25)
        renderMock3D.distance = 222
        function renderMock3D:LayoutEntity( Entity ) return end -- disables default rotation

        function renderMock3D:PreDrawModel()
            frame.csent2:DrawModel()
            mover:update(box_moveaway:GetChecked() and 222 or 400)
            hoverer:update(box_hovering:GetChecked() and 0 or 120)
            renderMock2D.cursorpos.x = 246 - hoverer.y
            self.distance = mover.y

            self:SetCamPos(Vector(self.distance, self.distance, self.distance))
        end

        function renderMock3D:PostDrawModel(ent)
            if not isSeatXrayEnabled() then return end
            if mover.y >= 300 then return end
            drawSeatHighlight(ent, hoverer.y < 60)
        end

        uiRenderer = seatUIRenderer()
        renderMock2D = LeftPanel:Add("DPanel")
        renderMock2D:Dock(FILL)
        renderMock2D.cursorpos = {x = 246, y = 271}
        function renderMock2D:Paint(w, h)
            local cursor = self.cursorpos

            surface.SetDrawColor(230, 240, 255)
            surface.DrawRect(cursor.x, cursor.y, 1, 1)
            local dist, size = 4, 8

            surface.DrawLine(cursor.x - dist, cursor.y, cursor.x - dist - size, cursor.y)
            surface.DrawLine(cursor.x + dist, cursor.y, cursor.x + dist + size, cursor.y)

            surface.DrawLine(cursor.x, cursor.y - dist, cursor.x, cursor.y - dist - size)
            surface.DrawLine(cursor.x, cursor.y + dist, cursor.x, cursor.y + dist + size)

            if not isSeatXrayEnabled() then return end
            if not seatxray_showhud:GetBool() then lastToggle = 0 return end

            uiRenderer(w, h, mover.y < 300 and {renderMock3D.Entity} or {}, (mover.y < 300 and hoverer.y < 60) and renderMock3D.Entity or nil)
        end
    end

    local function closePreferences()
        if not IsValid(frame) then return end
        frame:Close()
    end

    concommand.Add("seatxray_preferences", function() openPreferences() end, nil, "Opens a visual preference editor that internally just modifies the seatxray_* convars, but adds a nice visual menu to show you in real time how it will look.")
    concommand.Add("seatxray_preferences_panic", function() closePreferences() end, nil, "Panic-removes the visual preference editor")
end