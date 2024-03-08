local use_max_distance = 400

local ceil = math.ceil
local clamp = math.Clamp
local pi = math.pi
local sqrt = math.sqrt
local curtime = CurTime
local IsValid = IsValid
--local realFrameTime = RealFrameTime

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
    local seatxray_enable  = CreateConVar("seatxray_enable",  1, FCVAR_ARCHIVE, "Enables/disables all seat xray functionality. This includes both behavior & visuals.")
    local seatxray_showhud = CreateConVar("seatxray_showhud", 1, FCVAR_ARCHIVE, "Enables/disables the prompt that comes up when a seat is detected.")

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

    timer.Create("march.seatxray.update", 1 / 10, 0, function()
        if not IsValid(LocalPlayer()) then return end -- prevents error where localplayer isn't initialized so getSeats complains
        seats = {}
        lookat = nil

        if not seatxray_enable:GetBool() then return end

        seats = getSeats()
        lookat = findNearestLookatSeat()
    end)

    hook.Add("PreDrawEffects", "march.seatxray.render3D", function()
        if not seatxray_enable:GetBool() then return end
        if LocalPlayer():InVehicle() then return end

        render.DepthRange(0, 0)
        for _, seat in ipairs(seats) do
            local b = 25525 -- make it crazy bright super simply
            if seat == lookat then
                local a = math.sin(CurTime() * 7) * 0.1
                render.SetBlend(0.2 + a)
            else
                render.SetBlend(0.1)
            end
            render.SetColorModulation(b,b,b)

            seat:DrawModel()
        end

        render.SetBlend(1)
        render.SetColorModulation(1,1,1)
        render.DepthRange(0, 1)
    end)

    local function center(x, y, w, h, ...)
        return x - (w / 2), y - (h / 2), w, h, ...
    end

    local f, z, r = 1.02, 0.7, -0.79
    local window_opacity, window_width, window_height = AnimationSmoother(f,z,r,0), AnimationSmoother(f,z,r,0), AnimationSmoother(f,z,r,0)
    local extra_text_movement, extra_text_opacity = AnimationSmoother(f,z,r,0), AnimationSmoother(1.4,z,r,0)
    local text = ""
    local lastToggle = 0

    hook.Add("HUDPaint", "march.seatxray.render2D", function()
        if not seatxray_enable:GetBool() then lastToggle = 0 return end
        if not seatxray_showhud:GetBool() then lastToggle = 0 return end
        if LocalPlayer():InVehicle() then lastToggle = 0 return end

        if window_opacity.y <= 0.01 and #seats == 0 then lastToggle = 0 return end

        local a, w, h = 0, 0, 0, 0, 0
        if #seats == 0 then
            w = window_width:update(0)
            h = window_height:update(0)
            a = window_opacity:update(0)
        else
            w = window_width:update(192)
            h = window_height:update(48)
            a = window_opacity:update(1)
            if lastToggle == 0 then
                lastToggle = CurTime()
            end
            text = #seats .. " seat" .. (#seats == 1 and "" or "s") .. " available"
        end

        local scrw, scrh = ScrW(), ScrH()
        local wd2, hd2 = scrw / 2, scrh / 2

        surface.SetDrawColor(10, 15, 20, 177 * a)
        surface.DrawRect(center(wd2, hd2 + 64, w, h))
        surface.SetDrawColor(220, 230, 255, 255 * a)
        surface.DrawOutlinedRect(center(wd2, hd2 + 64, w, h, 1))

        local xM, xA
        if IsValid(lookat) then
            vtext = "Press [" .. string.upper(input.LookupBinding("+use")) .. "] to enter vehicle #" .. lookat:EntIndex()
            xM = extra_text_movement:update(8)
            xA = extra_text_opacity:update(1)
        else
            xM = extra_text_movement:update(0)
            xA = extra_text_opacity:update(0)
        end

        draw.SimpleText(text, "DermaDefault", wd2, (hd2 + 64) - xM, Color(220, 230, 255, 255 * a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        draw.SimpleText(vtext, "DermaDefault", wd2, (hd2 + 64) + xM, Color(220, 230, 255, 255 * xA), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        local drawtextalpha2 = (math.Clamp(CurTime() - lastToggle, 4, 6) - 4) / 2

        draw.SimpleText("(want to remove this prompt? type seatxray_showhud 0 in console.)", "DermaDefault", wd2, (hd2 + 64) + 32, Color(255, 255, 255, 255 * a * drawtextalpha2), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end)

    hook.Add("KeyPress", "march.seatxray.use_hook", function(_, key)
        if not seatxray_enable:GetBool() then return end
        if key == IN_USE and IsFirstTimePredicted() and not LocalPlayer():InVehicle() then
            local seat = findNearestLookatSeat()
            if seat == nil then return end

            net.Start("march.seatxray.request_use")
            net.WriteEntity(seat)
            net.SendToServer()
        end
    end)
end