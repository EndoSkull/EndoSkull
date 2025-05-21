-- Project: WWII A-Scope Radar
-- V31: Added functionality to increment minimum range (g_mn_r) using I_BTN_INC_MN (channel 7).
-- V30: Code review and re-confirmation of V29 logic.
-- V29: Removed all screen.drawText calls from onDraw.
-- V28: Correctly moved O_ECG_BEAT_OUT logic to onTick using a flag from onDraw.
-- V26: Adjusted peak trigger condition in onDraw to prevent occasional visual skips.

-- Input/Output Aliases
local igN = input.getNumber
local igB = input.getBool
local pgN = property.getNumber -- Defined as requested, though not currently used in the script
local isN = output.setNumber
local isB = output.setBool

-- Configs
BEAM_W=5;TRK_LIFE=30;TPS=60;TRK_LIFE_T=TRK_LIFE*TPS;MAX_R=20000;MIN_R_MIN=0;R_STEP=500;MIN_R_SPAN=1000;
SCR_W=64;SCR_H=64;MRG=4;BASE_Y=SCR_H/2;MAX_PK_H=BASE_Y-MRG;SRF_ALT_C=200;DEF_SPD=0.025;
SRCH_SPD_F=0.5;SRCH_ARC_D=20;CORR_BRG_TOL=7.5;CORR_DIST_TOL=150;
ECG_INT_T=45;ECG_RISE_T=5;ECG_FALL_T=8;ECG_ADD_H=10;ECG_W=5;ECG_REST_H=1;
BASE_SWP_S=2;
ANIM_SPD_M=0.5;

-- Inputs
I_SENS_FND=1;I_SENS_D=1;I_SENS_AZ=2;I_SENS_EL=3;
I_BTN_INC_MX=5;I_BTN_DEC_MX=6;I_BTN_LCK=9;I_BTN_DEC_MN=8;I_BTN_PWR=10;
I_BTN_INC_MN=7; -- New: Button Increase Min Range
I_RAD_BRG=17;I_SHIP_H=18;

-- Outputs
O_MAX_R=1;O_MIN_R=2;O_RAD_SPD=3;O_W_BRG=4;O_R_BRG=5;O_D1_AZ=6;O_D1_D=7;O_D1_ALT=8;O_D1_EL=9;
O_R_SPAN=10;O_ACT_TRK=11;O_D_RAW_D=12;O_D_MAP_X=13;O_IS_PWR=14;O_ECG_BEAT_OUT=15;

-- Globals
g_t=0;g_mn_r=MIN_R_MIN;g_mx_r=5000;g_pwr=false;g_nxt_id=1;g_trks={};g_fcs_trk=nil;
g_lck_st=0;g_srch_c_brg=nil;g_srch_dir=1;
g_prv_b={ -- Added I_BTN_INC_MN
    [I_BTN_INC_MX]=false,[I_BTN_DEC_MX]=false,
    [I_BTN_DEC_MN]=false,[I_BTN_INC_MN]=false, 
    [I_BTN_PWR]=false,[I_BTN_LCK]=false
}
g_swp_x=MRG;g_d_t1="";g_d_t2="";g_d_t3="";g_d_t4="";

g_swp_drw_st = "sweeping" -- Current state of the sweep line drawing: "sweeping" or "peaking"
g_pk_drw_inf = nil      -- Information about the target being peaked: { x_pos, base_h, id }
g_pk_drw_st_t = 0       -- Game tick when the current peak animation started
g_peak_drawn_last_frame = false -- Flag set by onDraw, read by onTick for O_ECG_BEAT_OUT

-- Helpers
function d(t)return t*360 end;function r(t)return t*2*math.pi end;function nd(a)a=a%360;if a<0 then a=a+360 end;return a end
function cl(v,mn,mx)return math.max(mn,math.min(v,mx))end;function mpV(v,im,ix,om,ox)if im==ix then return om end;return(v-im)*(ox-om)/(ix-im)+om end
function ad(a1,a2)local df=nd(a1-a2);if df>180 then df=360-df end;return df end

-- Tick
function onTick()
    g_t=g_t+1;local bIncMx=igB(I_BTN_INC_MX);local bDecMx=igB(I_BTN_DEC_MX)
    local bDecMn=igB(I_BTN_DEC_MN); local bIncMn=igB(I_BTN_INC_MN) -- Read new button state
    local bLckH=igB(I_BTN_LCK);local bPwrP=igB(I_BTN_PWR)

    local s_anim_m = math.max(0.01, ANIM_SPD_M) -- Safe animation speed multiplier
    local eff_ecg_it_c = ECG_INT_T / s_anim_m   -- Effective ECG interval time for calculations

    -- Handle power button press
    if bPwrP and not g_prv_b[I_BTN_PWR] then
        g_pwr=not g_pwr;
        if not g_pwr then -- Reset states if powered off
            g_trks={};g_fcs_trk=nil;g_lck_st=0;g_srch_dir=1;
            g_swp_drw_st = "sweeping"; g_pk_drw_inf = nil;
            g_peak_drawn_last_frame = false; -- Ensure flag is reset if powered off
        end
    end
    g_prv_b[I_BTN_PWR]=bPwrP;isB(O_IS_PWR,g_pwr)

    -- Handle range adjustment buttons
    if bIncMx and not g_prv_b[I_BTN_INC_MX]then g_mx_r=math.min(g_mx_r+R_STEP,MAX_R)end
    if bDecMx and not g_prv_b[I_BTN_DEC_MX]then g_mx_r=math.max(g_mx_r-R_STEP,g_mn_r+MIN_R_SPAN)end
    if bDecMn and not g_prv_b[I_BTN_DEC_MN]then 
        g_mn_r=math.max(g_mn_r-R_STEP,MIN_R_MIN)
        g_mx_r=math.max(g_mx_r,g_mn_r+MIN_R_SPAN) -- Ensure max range is adjusted if min range drops too low
    end
    if bIncMn and not g_prv_b[I_BTN_INC_MN]then -- New: Handle Increase Min Range
        g_mn_r=math.min(g_mn_r+R_STEP, g_mx_r-MIN_R_SPAN) 
    end

    g_prv_b[I_BTN_INC_MX]=bIncMx;g_prv_b[I_BTN_DEC_MX]=bDecMx
    g_prv_b[I_BTN_DEC_MN]=bDecMn;g_prv_b[I_BTN_INC_MN]=bIncMn -- Store new button state
    g_prv_b[I_BTN_LCK]=bLckH

    local prev_fcs = g_fcs_trk -- Store previous focused track for comparison
    g_fcs_trk=nil             -- Reset focused track for this tick
    local in_bm=false           -- Flag: is any target in the radar beam

    -- If radar is off, set outputs to off/default states and return
    if not g_pwr then
        isN(O_RAD_SPD,0);isN(O_MAX_R,g_mx_r);isN(O_MIN_R,g_mn_r);isN(O_R_SPAN,g_mx_r-g_mn_r)
        isN(O_ACT_TRK,#g_trks);isN(O_W_BRG,0);isN(O_R_BRG,0);isN(O_D1_AZ,0);isN(O_D1_D,0)
        isN(O_D1_ALT,0);isN(O_D1_EL,0);isN(O_D_RAW_D,0);isN(O_D_MAP_X,0)
        isB(O_ECG_BEAT_OUT, false) -- Explicitly set to false if radar is off
        return
    end

    -- Calculate radar world bearing
    local r_brg_t=igN(I_RAD_BRG);local s_hdg_t=igN(I_SHIP_H);local r_rel_d=nd(d(r_brg_t));local s_hdg_d=nd(d(s_hdg_t));local r_w_d=nd(s_hdg_d+r_rel_d)

    -- Process sensor input if a detection is found
    if igB(I_SENS_FND)then local dt_d=igN(I_SENS_D);local dt_az_t=igN(I_SENS_AZ);local dt_el_t=igN(I_SENS_EL)
        if dt_d>0.001 then -- Ensure valid distance
            local dt_w_d=nd(r_w_d+d(dt_az_t));local dt_alt=dt_d*math.tan(r(dt_el_t));local mtch=false
            for i=#g_trks,1,-1 do local trk=g_trks[i]
                if ad(trk.w_brg_d,dt_w_d)<=CORR_BRG_TOL and math.abs(trk.dist-dt_d)<=CORR_DIST_TOL then
                    trk.dist=dt_d;trk.az_rt=dt_az_t;trk.el_rt=dt_el_t
                    trk.w_brg_d=dt_w_d;trk.alt=dt_alt;trk.exp_t=g_t+TRK_LIFE_T;trk.last_upd_t=g_t;mtch=true;break
                end
            end
            if not mtch then
                table.insert(g_trks,{id=g_nxt_id,dist=dt_d,az_rt=dt_az_t,el_rt=dt_el_t,w_brg_d=dt_w_d,alt=dt_alt,exp_t=g_t+TRK_LIFE_T,last_upd_t=g_t,l_beat_t=g_t-(eff_ecg_it_c/2)});g_nxt_id=g_nxt_id+1
            end
        end
    end

    -- Remove expired tracks
    local tmp_trks={};for i=1,#g_trks do if g_t<g_trks[i].exp_t then table.insert(tmp_trks,g_trks[i])end end;g_trks=tmp_trks

    -- Determine focused track
    local f_bm_d=0;local f_bm_x=0;local f_bm_p=false;local d1az,d1d,d1a,d1e=0,0,0,0
    for i=1,#g_trks do local trk=g_trks[i];local in_r=(trk.dist>=g_mn_r and trk.dist<=g_mx_r)
        if in_r then local cur_trk_az_d=ad(trk.w_brg_d,r_w_d);local is_trk_bm=(math.abs(cur_trk_az_d)<=BEAM_W)
            if is_trk_bm then in_bm=true 
                if not g_fcs_trk then 
                    local x=mpV(trk.dist,g_mn_r,g_mx_r,MRG,SCR_W-MRG);x=cl(x,MRG,SCR_W-MRG)
                    local n_alt=cl(trk.alt,0,SRF_ALT_C);local c_pk_h=mpV(n_alt,0,SRF_ALT_C,0,MAX_PK_H);local b_pk_h=math.max(c_pk_h,1.0)
                    local lbt_val=(trk.l_beat_t or(prev_fcs and prev_fcs.id==trk.id and prev_fcs.l_beat_t)or(g_t-eff_ecg_it_c))
                    g_fcs_trk={id=trk.id,x_pos=x,base_h=b_pk_h,l_beat_t=lbt_val,dist=trk.dist,alt=trk.alt,el_rt=trk.el_rt,trk_az_d=cur_trk_az_d, is_beat=false}
                    f_bm_d=trk.dist;f_bm_x=x;
                    d1az=cur_trk_az_d;d1d=trk.dist;d1a=trk.alt;d1e=trk.el_rt;f_bm_p=true
                end
            end
        end
    end

    -- Set outputs for focused target details
    isN(O_D1_AZ,d1az);isN(O_D1_D,d1d);isN(O_D1_ALT,d1a);isN(O_D1_EL,d1e)
    isN(O_D_RAW_D,f_bm_d);isN(O_D_MAP_X,f_bm_x)

    -- Handle heartbeat TIMING logic for focused track (sets g_fcs_trk.is_beat)
    if g_fcs_trk then
        local eff_it = ECG_INT_T / s_anim_m 
        local eff_rt = ECG_RISE_T / s_anim_m
        local eff_ft = ECG_FALL_T / s_anim_m

        if g_t - g_fcs_trk.l_beat_t >= eff_it then
            g_fcs_trk.l_beat_t = g_t
            for k = 1, #g_trks do
                if g_trks[k].id == g_fcs_trk.id then
                    g_trks[k].l_beat_t = g_t
                    break
                end
            end
        end
        g_fcs_trk.is_beat = (g_t - g_fcs_trk.l_beat_t >= 0 and g_t - g_fcs_trk.l_beat_t < eff_rt + eff_ft)
    else
        if prev_fcs then prev_fcs.is_beat = false end 
    end

    -- Radar sweep speed and lock logic
    local d_spd=DEF_SPD
    if bLckH then 
        if in_bm then 
            if g_lck_st~=2 then g_srch_c_brg=r_w_d end 
            g_lck_st=2;d_spd=0 
        else 
            if g_lck_st==2 then 
                g_lck_st=3 
                if g_srch_c_brg then d_spd=DEF_SPD*SRCH_SPD_F*g_srch_dir else g_lck_st=1;d_spd=DEF_SPD end
            elseif g_lck_st==3 then 
                if g_srch_c_brg then d_spd=DEF_SPD*SRCH_SPD_F*g_srch_dir
                    if math.abs(ad(r_w_d,g_srch_c_brg))>=SRCH_ARC_D/2 then g_srch_dir=g_srch_dir*-1;d_spd=DEF_SPD*SRCH_SPD_F*g_srch_dir end
                else g_lck_st=1;d_spd=DEF_SPD end 
            else 
                g_lck_st=1;d_spd=DEF_SPD 
            end
        end
    else 
        g_lck_st=0;d_spd=DEF_SPD;g_srch_dir=1 
    end
    isN(O_RAD_SPD,d_spd)

    if g_pwr then
        isB(O_ECG_BEAT_OUT, g_peak_drawn_last_frame)
    end 

    isN(O_MAX_R,g_mx_r);isN(O_MIN_R,g_mn_r);isN(O_W_BRG,r_w_d);isN(O_R_BRG,r_rel_d)
    isN(O_R_SPAN,g_mx_r-g_mn_r);isN(O_ACT_TRK,#g_trks)
end

-- Draw
function onDraw()
    g_peak_drawn_last_frame = false

    if not g_pwr then
        screen.setColor(100,100,100,255);screen.drawClear() 
        g_swp_drw_st = "sweeping"; g_pk_drw_inf = nil; 
        return
    end

    if g_swp_drw_st == "peaking" then
        if not g_fcs_trk or (g_pk_drw_inf and g_fcs_trk.id ~= g_pk_drw_inf.id) then
            g_swp_drw_st = "sweeping"
            if g_pk_drw_inf then g_swp_x = g_pk_drw_inf.x_pos else g_swp_x = g_swp_x end 
            g_pk_drw_inf = nil
        end
    end

    local s_anim_m = math.max(0.01, ANIM_SPD_M)    
    local swp_inc = BASE_SWP_S * s_anim_m          
    local eff_rt_drw = ECG_RISE_T / s_anim_m       
    local eff_ft_drw = ECG_FALL_T / s_anim_m       
    local pk_dur = eff_rt_drw + eff_ft_drw         

    local vis_swp_x = g_swp_x 

    screen.setColor(0,255,0,255) 

    if g_swp_drw_st == "peaking" and g_pk_drw_inf then
        local pk_center_x = g_pk_drw_inf.x_pos
        local pk_left_x = cl(pk_center_x - ECG_W / 2, MRG, SCR_W - MRG - 1)
        
        vis_swp_x = pk_left_x 
        screen.drawLine(MRG, BASE_Y, vis_swp_x, BASE_Y)

        local el_b_drw = g_t - g_pk_drw_st_t 
        local pk_h = ECG_REST_H             
        local pk_base_h = g_pk_drw_inf.base_h 

        if el_b_drw >= 0 then
            if el_b_drw < eff_rt_drw then 
                local p = el_b_drw / math.max(1, eff_rt_drw) 
                pk_h = ECG_REST_H + p * (pk_base_h + ECG_ADD_H - ECG_REST_H)
            elseif el_b_drw < pk_dur then 
                local pf = (el_b_drw - eff_rt_drw) / math.max(1, eff_ft_drw) 
                pk_h = (pk_base_h + ECG_ADD_H) - pf * (pk_base_h + ECG_ADD_H - ECG_REST_H)
            end
        end
        pk_h = cl(pk_h, ECG_REST_H, MAX_PK_H) 

        if pk_h > ECG_REST_H then
            local peak_draw_xl = pk_left_x 
            local peak_draw_xr = cl(pk_center_x + ECG_W / 2, MRG, SCR_W - MRG - 1) 
            local yt = cl(BASE_Y - pk_h, 0, SCR_H - 1) 
            screen.drawLine(peak_draw_xl, BASE_Y, pk_center_x, yt) 
            screen.drawLine(pk_center_x, yt, peak_draw_xr, BASE_Y) 
            g_peak_drawn_last_frame = true 
        end

        if el_b_drw >= pk_dur then
            g_swp_x = pk_center_x 
            g_swp_drw_st = "sweeping"
            g_pk_drw_inf = nil
        end

    else 
        local prev_swp_log_x = g_swp_x     
        g_swp_x = g_swp_x + swp_inc        

        local to_peak_st = false           
        local pk_tgt_x = 0                 

        if g_fcs_trk and g_fcs_trk.is_beat then 
            pk_tgt_x = g_fcs_trk.x_pos 
            if prev_swp_log_x <= pk_tgt_x and g_swp_x >= pk_tgt_x then
                 if pk_tgt_x >= MRG and pk_tgt_x <= SCR_W - MRG then 
                    to_peak_st = true
                end
            end
        end

        if to_peak_st then 
            g_swp_drw_st = "peaking"
            g_pk_drw_inf = { x_pos = pk_tgt_x, base_h = g_fcs_trk.base_h, id = g_fcs_trk.id }
            g_pk_drw_st_t = g_t
            g_swp_x = pk_tgt_x 
            
            local pk_left_x_trans = cl(pk_tgt_x - ECG_W / 2, MRG, SCR_W - MRG - 1)
            vis_swp_x = pk_left_x_trans 
        else 
            if g_swp_x > (SCR_W - MRG) + swp_inc / 2 then
                g_swp_x = MRG
            end
            vis_swp_x = cl(g_swp_x, MRG, SCR_W - MRG) 
        end
        screen.drawLine(MRG, BASE_Y, vis_swp_x, BASE_Y) 
    end

    screen.drawLine(MRG,BASE_Y-2,MRG,BASE_Y+2) 
    if vis_swp_x >= SCR_W-MRG and g_swp_drw_st == "sweeping" then
        screen.drawLine(SCR_W-MRG,BASE_Y-2,SCR_W-MRG,BASE_Y+2)
    end
end
