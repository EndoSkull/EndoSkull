--[[
WWII-Style PPI Radar Scope for Stormworks 64x64 Monitor
Version 1.5.24 (Corrected Contact Bearing at Detection)

Changes:
- Modified onTick() contact processing:
  - When a target is detected (tF = true), its world bearing (tWT) for storage
    and subsequent drawing is now calculated based on the ship's heading (shw_T)
    and the radar's current bearing relative to the ship (rbs_T) ONLY.
  - The target's relative azimuth (azT) from the Phalanx system is no longer
    added to this calculation for positioning the blip. This ensures that
    newly detected contacts appear directly under the sweep line's leading edge.
  - The raw azT is still read and used for the debug output cDT1A_O.
- This addresses the issue where contacts could appear "ahead" of the sweep
  if azT was non-zero.
- All other logic (fading, scaling, sweep drawing, EDGE_VISUAL_FACTOR, input mappings)
  from v1.5.23 (longer sweep needle) / v1.5.19 (referred to as "Mostly Working") remains.
]]

-- Screen Dimensions
local S_W, S_H = 64, 64
local S_CX, S_CY = S_W / 2, S_H / 2

-- Aliases
local gB = input.getBool
local gN = input.getNumber
local sB = output.setBool
local sN = output.setNumber
local pP = property.getNumber -- Property Number

local mPi = math.pi
local mFlr = math.floor
local mMin = math.min
local mMax = math.max
local mSin = math.sin
local mCos = math.cos
local mAbs = math.abs

local scr = screen
local sC = scr.setColor
local sCl = scr.drawClear
local sL = scr.drawLine
local sCF = scr.drawCircleF

-- Input Channel Constants (Boolean) - REMAPPED
local cIncMR = 5   -- Increase Max Range
local cDecMR = 6   -- Decrease Max Range
local cIncMnR = 7  -- Increase Min Range
local cDecMnR = 8  -- Decrease Min Range

-- Phalanx Target Found Boolean Inputs (User must adapt wiring) - REMAPPED
local cPTF_BASE = 1 -- Base Boolean channel for Phalanx Target Found flags
                     -- T1_Found: cPTF_BASE + 0 (Bool 1)
                     -- T2_Found: cPTF_BASE + 1 (Bool 2)
                     -- T3_Found: cPTF_BASE + 2 (Bool 3)
                     -- T4_Found: cPTF_BASE + 3 (Bool 4)

-- Input Channel Constants (Number)
local cPNDB = 1  -- Phalanx Number Data Base (Number Channel 1)
local cPNDO = 0  -- Phalanx Number Dist Offset
local cPNAO = 1  -- Phalanx Number Azim Offset
local cPNPT = 4  -- Phalanx Numbers Per Target

local cRBS = 17  -- Radar Bearing Ship (Number)
local cSHW = 18  -- Ship Heading World (Number)

-- Output Channel Constants (Boolean)
local cCSR = 1   -- Cmd Stop Rotation

-- Output Channel Constants (Number)
local cCMR_O = 1 -- Cur Max Range Out
local cCMnR_O = 2-- Cur Min Range Out
local cBTR_O = 3 -- Boresight Target Range Out
local cAWB_O = 4 -- Antenna World Bearing Out
local cDRBS_O = 5-- Dbg Radar Bearing Ship Out
local cDT1A_O = 6-- Dbg T1 Azim Out
local cDT1D_O = 7-- Dbg T1 Dist Out
local cDRS_O = 8 -- Dbg Range Span Out

-- Script Property Constants
local pCLS_P = 1 -- Property Contact Lifetime Sec

-- Visual Config
local BG_C = {r=0, g=30, b=0} 
local GRT_C = {r=0, g=100, b=0} 
local SWP_C = {r=0, g=255, b=0} 
local CNT_N_C = {r=0, g=255, b=0} -- Contact New Color
local CNT_O_C = {r=0, g=100, b=0} -- Contact Old Color

-- Default & Configurable Params
local DEF_CL = 30 
local pCL = DEF_CL -- prop_cntLife

-- Graticule Alphas
local GRT_A1, GRT_A2, GRT_A3, GRT_A4 = 100, 80, 60, 40
local GRT_LA = 70 -- Line Alpha

-- Sweep Config
local SWP_WT = 0.05 -- Width Turns (Angular width of the sweep trail)
local SWP_AS = 200  -- Alpha Start
local SWP_AE = 10   -- Alpha End
local SWP_LN = 10   -- Lines (visual segments in the trail)

-- Radar Mechanics
local MAX_T = 4 -- MAX_TGTS
local EDGE_VISUAL_FACTOR = 5.0 -- Factor to ensure ct.dist=cmr hits the "visual hard edge"

-- Runtime Vars
local cts = {} -- contacts (for data persistence: lifetime, debug, auto-stop, AND DRAWING)

local rbs_T = 0 -- rdrBrngS_T (radar bearing relative to ship, in turns, 0-1)
local shw_T = 0 -- shpHeadW_T (ship heading world, in turns, 0-1)
local hDT1D = 0 -- held_dbg_t1_dist

local cmr = 5000 -- curMaxR
local cmnr = 50  -- curMinR
local rStep = 500
local mPR = 20000 -- maxPossR (Max range cap)
local mnPR = 0    -- minPossR
local MIN_RS = 50 -- MIN_RANGE_SPAN

local aSM = false -- autoStpM
local cSR = false -- cmdStpRot
local bTR = 0     -- bsTgtR

-- Prev button states
local pIMR, pDMR, pIMnR, pDMnR = false, false, false, false

local function rnd(x) return mFlr(x + 0.5) end

function onTick()
    rbs_T = gN(cRBS) or 0
    shw_T = gN(cSHW) or 0

    local bIMR_p = gB(cIncMR) 
    local bDMR_p = gB(cDecMR) 
    local bIMnR_p = gB(cIncMnR) 
    local bDMnR_p = gB(cDecMnR) 

    pCL = pP(pCLS_P)
    if pCL <= 0 then pCL = DEF_CL end
    local pCL_t = pCL * 60 -- ticks

    local uAMR, uAMnR = false, false 

    if bIMR_p and not pIMR then cmr = mMin(cmr + rStep, mPR); uAMR = true; end
    if bDMR_p and not pDMR then cmr = mMax(cmr - rStep, 100); uAMR = true; end
    if bIMnR_p and not pIMnR then cmnr = mMin(cmnr + rStep, mPR - MIN_RS); uAMnR = true; end
    if bDMnR_p and not pDMnR then cmnr = mMax(cmnr - rStep, mnPR); uAMnR = true; end
    
    pIMR, pDMR, pIMnR, pDMnR = bIMR_p, bDMR_p, bIMnR_p, bDMnR_p

    if uAMR then
        cmnr = mMin(cmnr, cmr - MIN_RS)
        cmnr = mMax(cmnr, mnPR)
        cmr = mMax(cmr, cmnr + MIN_RS) 
        cmr = mMax(cmr, 100) 
    end
    if uAMnR and not uAMR then
        cmr = mMax(cmr, cmnr + MIN_RS)
        cmr = mMin(cmr, mPR)
        cmnr = mMin(cmnr, cmr - MIN_RS)
        cmnr = mMax(cmnr, mnPR)
    end
 
    cmnr = mMax(mnPR, cmnr) 
    cmr = mMax(100, cmr) 
    if cmnr >= cmr - MIN_RS + 1 then cmnr = cmr - MIN_RS end
    cmnr = mMax(mnPR, cmnr) 
    cmr = mMax(cmnr + MIN_RS, cmr)
    cmr = mMin(mPR, cmr) 
    cmr = mMax(100, cmr) 

    if cmnr < 50 then
        cmnr = 50
        cmr = mMax(cmr, cmnr + MIN_RS)
        cmr = mMin(cmr, mPR) 
        cmr = mMax(cmr, 100)     
    end

    local rbs_D = rbs_T * 360 
    local fBSAST = false 
    local cBSDAS = cmr + 1 
    
    local ctT1D = 0 
    local rT1A_T = 0  -- This will store the raw Azimuth of T1 for debug, if detected.

    if gB(cPTF_BASE + 0) then -- Target 1 Found (Bool cPTF_BASE + 0)
        ctT1D = gN(cPNDB + (0 * cPNPT) + cPNDO) or 0
        -- Read the raw azT for Target 1 for debug output, but it won't be used for positioning.
        rT1A_T = gN(cPNDB + (0 * cPNPT) + cPNAO) or 0 
        if ctT1D ~= 0 and ctT1D ~= hDT1D then hDT1D = ctT1D end
    end

    for i = 0, MAX_T - 1 do
        local tF = gB(cPTF_BASE + i) -- tgtFound from REMAPPED bool channels
        if tF then 
            local d = gN(cPNDB + (i * cPNPT) + cPNDO) or 0
            local azT_raw = gN(cPNDB + (i * cPNPT) + cPNAO) or 0 -- Raw azimuth from Phalanx
            
            -- CRITICAL CHANGE HERE: Calculate Target World Turns (tWT) using ONLY
            -- ship heading (shw_T) and radar bearing relative to ship (rbs_T).
            -- The raw azT_raw is IGNORED for positioning the blip, ensuring it appears
            -- under the sweep's leading edge.
            local tWT = (shw_T + rbs_T) % 1.0 
            if tWT < 0 then tWT = tWT + 1.0 end
            local tWK = mFlr(tWT * 3600) 
            
            cts[tWK] = {dist = d, wrbRad = tWT * 2 * mPi, life = pCL_t, rfrsh = true}

            if aSM and d >= cmnr and d <= cmr then 
                fBSAST = true
                if d < cBSDAS then cBSDAS = d end
            end
        end
    end

    local nCts = {} 
    for key, ct_data in pairs(cts) do
        if ct_data.rfrsh then 
            ct_data.rfrsh = false; nCts[key] = ct_data
        else 
            ct_data.life = ct_data.life - 1; if ct_data.life > 0 then nCts[key] = ct_data end 
        end
    end
    cts = nCts 

    if aSM and fBSAST then cSR = true; bTR = cBSDAS
    else cSR = false; bTR = 0 end

    local awb_T = (shw_T + rbs_T) % 1.0 
    if awb_T < 0 then awb_T = awb_T + 1.0 end
    local awb_D = awb_T * 360 

    sB(cCSR, cSR)
    sN(cCMR_O, cmr)
    sN(cCMnR_O, cmnr)
    sN(cBTR_O, bTR)
    sN(cAWB_O, awb_D)
    sN(cDRBS_O, rbs_D)
    sN(cDT1A_O, rT1A_T * 360) -- Outputting the raw T1 Azimuth for debug
    sN(cDT1D_O, hDT1D) 
    sN(cDRS_O, cmr - cmnr)
end

function onDraw()
    local mSR = (mMin(S_W, S_H) / 2) - 1 
    if mSR < 1 then mSR = 1 end 

    sC(BG_C.r, BG_C.g, BG_C.b); sCl()

    local nGR = 4 
    for i = 1, nGR do
        local rR = i / nGR; local rRPx = rR * mSR 
        local alp = GRT_A4 
        if i == 1 then alp = GRT_A1 elseif i == 2 then alp = GRT_A2 elseif i == 3 then alp = GRT_A3 end
        sC(GRT_C.r, GRT_C.g, GRT_C.b, alp)
        sCF(S_CX, S_CY, mFlr(rRPx)) 
    end

    sC(GRT_C.r, GRT_C.g, GRT_C.b, GRT_LA)
    sL(0, S_CY, S_W, S_CY) 
    sL(S_CX, 0, S_CX, S_H) 

    local pCL_t = pCL * 60 
    
    for key, ct in pairs(cts) do
        if ct.life > 0 and ct.dist >= cmnr and cmr > 0 then
            local carbr = ct.wrbRad - (shw_T * 2 * mPi) 
            local nD = ct.dist / cmr 
            local bRPx = nD * mSR * EDGE_VISUAL_FACTOR 
            
            local bXf = S_CX + bRPx * mSin(carbr) 
            local bYf = S_CY - bRPx * mCos(carbr) 
            
            local bX = rnd(bXf); local bY = rnd(bYf) 
            
            local ageR = ct.life / pCL_t 
            ageR = mMax(0, mMin(1, ageR)) 
            
            local rV = CNT_O_C.r + (CNT_N_C.r - CNT_O_C.r) * ageR 
            local gV = CNT_O_C.g + (CNT_N_C.g - CNT_O_C.g) * ageR 
            local bV = CNT_O_C.b + (CNT_N_C.b - CNT_O_C.b) * ageR 
            local alpV = 50 + 205 * ageR 
            
            sC(mFlr(rV), mFlr(gV), mFlr(bV), mFlr(alpV))
            sCF(bX, bY, 1) 
        end
    end

    local sweep_leading_edge_disp_rad = rbs_T * 2 * mPi 
    local sweep_display_radius = mSR + 20 

    for idx = 0, SWP_LN -1 do 
        local lnP = idx / SWP_LN 
        local trail_offset_rad = lnP * SWP_WT * 2 * mPi
        local current_segment_disp_rad = sweep_leading_edge_disp_rad - trail_offset_rad
        
        local alp = SWP_AS - (lnP * (SWP_AS - SWP_AE))
        alp = mMax(0, mMin(255, mFlr(alp))) 
        
        sC(SWP_C.r, SWP_C.g, SWP_C.b, alp)
        local eX = S_CX + sweep_display_radius * mSin(current_segment_disp_rad)
        local eY = S_CY - sweep_display_radius * mCos(current_segment_disp_rad) 
        sL(S_CX, S_CY, mFlr(eX), mFlr(eY))
    end
end
