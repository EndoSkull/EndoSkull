--[[
WWII-Style PPI Radar Scope for Stormworks 64x64 Monitor
Version 1.5.30 (Standard Proportional Scaling)

Changes:
- Set EDGE_VISUAL_FACTOR to 1.0.
  - This restores a direct proportional scaling where a contact at the
    current max range (cmr) setting will appear at the outermost radius (mSR)
    of the drawn graticules.
  - Contacts closer than cmr will be scaled linearly within this radius.
  - Contacts farther than cmr will be scaled beyond mSR and thus clipped
    at the screen edge by Stormworks.
- This addresses previous observations of non-proportional scaling.
- All other logic from v1.5.29 (which was based on v1.5.28) remains.
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

-- Input Channel Constants (Boolean)
local cSFND = 1    -- Sensor Found (NEW PRIMARY TRIGGER)
-- Range Controls
local cIncMR = 5   -- Increase Max Range
local cDecMR = 6   -- Decrease Max Range
local cIncMnR = 7  -- Increase Min Range
local cDecMnR = 8  -- Decrease Min Range

-- Input Channel Constants (Number)
-- Sensor Data Inputs
local cSDIST = 1   -- Sensor Distance
local cSAZIM = 2   -- Sensor Azimuth (relative to radar, turns)
local cSELEV = 3   -- Sensor Elevation (relative to radar, turns)

-- Existing Contextual Inputs
local cRBS = 17  -- Radar Bearing Ship (Number, turns)
local cSHW = 18  -- Ship Heading World (Number, turns)

-- Output Channel Constants (Boolean)
local cCSR = 1   -- Cmd Stop Rotation

-- Output Channel Constants (Number)
local cCMR_O = 1 -- Cur Max Range Out
local cCMnR_O = 2-- Cur Min Range Out
local cBTR_O = 3 -- Boresight Target Range Out
local cAWB_O = 4 -- Antenna World Bearing Out
local cDRBS_O = 5-- Dbg Radar Bearing Ship Out
local cDT1A_O = 6-- Dbg T1 Azim Out (Now last processed ping's relative azimuth)
local cDT1D_O = 7-- Dbg T1 Dist Out (Now last processed ping's distance)
local cDRS_O = 8 -- Dbg Range Span Out

-- Script Property Constants
local pCLS_P = 1 -- Property Contact Lifetime Sec

-- Visual Config
local BG_C = {r=0, g=30, b=0} 
local GRT_C = {r=0, g=100, b=0} 
local SWP_C = {r=0, g=255, b=0} 
local CNT_N_C = {r=0, g=255, b=0} 
local CNT_O_C = {r=0, g=100, b=0} 

-- Default & Configurable Params
local DEF_CL = 30 
local pCL = DEF_CL 

-- Graticule Alphas
local GRT_A1, GRT_A2, GRT_A3, GRT_A4 = 100, 80, 60, 40
local GRT_LA = 70 

-- Sweep Config
local SWP_WT = 0.05 
local SWP_AS = 200  
local SWP_AE = 10   
local SWP_LN = 10   

-- Radar Mechanics
local EDGE_VISUAL_FACTOR = 1.0 -- STANDARD PROPORTIONAL SCALING: cmr maps to mSR
local CORR_BRG_TOL_DEG = 2.5 
local CORR_DIST_TOL = 50     
local CORR_BRG_TOL_TURNS = CORR_BRG_TOL_DEG / 360 

-- Runtime Vars
local cts = {} -- Array of track objects: {dist, wrbRad, life}

local rbs_T = 0 
local shw_T = 0 
local last_ping_rel_az_T = 0 
local last_ping_dist = 0     

local cmr = 5000 
local cmnr = 50  
local rStep = 500
local mPR = 20000 
local mnPR = 0    
local MIN_RS = 50 

local aSM = false 
local cSR = false 
local bTR = 0     

-- Prev button states
local pIMR, pDMR, pIMnR, pDMnR = false, false, false, false

local function rnd(x) return mFlr(x + 0.5) end

local function normalizeTurns(angle_T)
    local norm_T = angle_T % 1.0
    if norm_T < 0 then norm_T = norm_T + 1.0 end
    return norm_T
end

local function angularDifferenceTurns(t1_norm, t2_norm)
    local diff = mAbs(t1_norm - t2_norm)
    if diff > 0.5 then diff = 1.0 - diff end
    return diff
end

function onTick()
    rbs_T = normalizeTurns(gN(cRBS) or 0) 
    shw_T = normalizeTurns(gN(cSHW) or 0) 

    -- Range Controls
    local bIMR_p = gB(cIncMR) 
    local bDMR_p = gB(cDecMR) 
    local bIMnR_p = gB(cIncMnR) 
    local bDMnR_p = gB(cDecMnR) 

    pCL = pP(pCLS_P)
    if pCL <= 0 then pCL = DEF_CL end
    local pCL_t = pCL * 60 -- Contact lifetime in ticks

    local uAMR, uAMnR = false, false 
    if bIMR_p and not pIMR then cmr = mMin(cmr + rStep, mPR); uAMR = true; end
    if bDMR_p and not pDMR then cmr = mMax(cmr - rStep, 100); uAMR = true; end
    if bIMnR_p and not pIMnR then cmnr = mMin(cmnr + rStep, mPR - MIN_RS); uAMnR = true; end
    if bDMnR_p and not pDMnR then cmnr = mMax(cmnr - rStep, mnPR); uAMnR = true; end
    pIMR, pDMR, pIMnR, pDMnR = bIMR_p, bDMR_p, bIMnR_p, bDMnR_p

    if uAMR then
        cmnr = mMin(cmnr, cmr - MIN_RS); cmnr = mMax(cmnr, mnPR)
        cmr = mMax(cmr, cmnr + MIN_RS); cmr = mMax(cmr, 100) 
    end
    if uAMnR and not uAMR then
        cmr = mMax(cmr, cmnr + MIN_RS); cmr = mMin(cmr, mPR)
        cmnr = mMin(cmnr, cmr - MIN_RS); cmnr = mMax(cmnr, mnPR)
    end
    cmnr = mMax(mnPR, cmnr); cmr = mMax(100, cmr) 
    if cmnr >= cmr - MIN_RS + 1 then cmnr = cmr - MIN_RS end
    cmnr = mMax(mnPR, cmnr); cmr = mMax(cmnr + MIN_RS, cmr)
    cmr = mMin(mPR, cmr); cmr = mMax(100, cmr) 
    if cmnr < 50 then
        cmnr = 50; cmr = mMax(cmr, cmnr + MIN_RS)
        cmr = mMin(cmr, mPR); cmr = mMax(cmr, 100)     
    end

    -- 1. Decrement life for all existing tracks
    for i = 1, #cts do
        cts[i].life = cts[i].life - 1
    end

    last_ping_rel_az_T = 0 
    last_ping_dist = 0

    if gB(cSFND) then 
        local dt_d = gN(cSDIST) or 0     
        local dt_az_T = gN(cSAZIM) or 0  
        -- local dt_el_T = gN(cSELEV) or 0 -- Not used for 2D PPI drawing

        last_ping_rel_az_T = dt_az_T 
        last_ping_dist = dt_d      

        if dt_d > 0.001 then 
            local radar_world_bearing_T = normalizeTurns(shw_T + rbs_T)
            local contact_world_bearing_T = normalizeTurns(radar_world_bearing_T + dt_az_T)
            
            local matched_existing_track = false
            for i = 1, #cts do
                local track = cts[i]
                -- Ensure track is still valid before trying to access its members
                if track and track.life > 0 then 
                    local track_world_bearing_T = normalizeTurns(track.wrbRad / (2 * mPi))
                    
                    local angular_diff_T = angularDifferenceTurns(track_world_bearing_T, contact_world_bearing_T)
                    local dist_diff = mAbs(track.dist - dt_d)

                    if angular_diff_T <= CORR_BRG_TOL_TURNS and dist_diff <= CORR_DIST_TOL then
                        track.dist = dt_d
                        track.wrbRad = contact_world_bearing_T * 2 * mPi
                        track.life = pCL_t -- Refresh lifetime
                        matched_existing_track = true
                        break
                    end
                end
            end

            if not matched_existing_track then
                table.insert(cts, {
                    dist = dt_d,
                    wrbRad = contact_world_bearing_T * 2 * mPi,
                    life = pCL_t
                })
            end
        end
    end

    -- 3. Filter out dead tracks
    local next_cts = {}
    for i = 1, #cts do
        if cts[i].life > 0 then
            table.insert(next_cts, cts[i])
        end
    end
    cts = next_cts
    
    -- Auto Stop Logic
    local fBSAST = false 
    local cBSDAS = cmr + 1 
    if aSM then
        for i = 1, #cts do
            local track = cts[i]
            if track.dist >= cmnr and track.dist <= cmr then
                fBSAST = true
                if track.dist < cBSDAS then cBSDAS = track.dist end
            end
        end
    end
    if aSM and fBSAST then cSR = true; bTR = cBSDAS
    else cSR = false; bTR = 0 end

    local rbs_D = rbs_T * 360 
    local awb_T = normalizeTurns(shw_T + rbs_T) 
    local awb_D = awb_T * 360 

    sB(cCSR, cSR)
    sN(cCMR_O, cmr)
    sN(cCMnR_O, cmnr)
    sN(cBTR_O, bTR)
    sN(cAWB_O, awb_D)
    sN(cDRBS_O, rbs_D)
    sN(cDT1A_O, last_ping_rel_az_T * 360) 
    sN(cDT1D_O, last_ping_dist) 
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
    
    for i = 1, #cts do
        local ct = cts[i]
        if ct.dist >= cmnr and cmr > 0 then 
            local carbr = ct.wrbRad - (shw_T * 2 * mPi) 
            local nD = ct.dist / cmr 
            local bRPx = nD * mSR * EDGE_VISUAL_FACTOR -- EDGE_VISUAL_FACTOR is now 1.0
            
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
