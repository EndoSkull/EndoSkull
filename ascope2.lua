--[[
Project: WWII A-Scope Radar
V19: Moved O_ECG_BEAT_OUT logic and output to onTick for compliance.
V18: Added ANIM_SPEED_MULTIPLIER for sweep and ECG animation speed.
     Added O_ECG_BEAT_OUT boolean output active during ECG peak.
V17: Refined lock state machine. Radar continues scanning if lock button
     is pressed but no target is in beam (State 1). Stops/wiggles only
     after a target is acquired while lock is active. Reset g_srch_dir.
V16: Further shortened variable names.
V15: Lock & re-acquire logic, halved default speed.
]]

-- Configs
BEAM_W=5;TRK_LIFE=30;TPS=60;TRK_LIFE_T=TRK_LIFE*TPS;MAX_R=20000;MIN_R_MIN=0;R_STEP=500;MIN_R_SPAN=1000;
SCR_W=64;SCR_H=64;MRG=4;BASE_Y=SCR_H/2;MAX_PK_H=BASE_Y-MRG;SRF_ALT_C=200;DEF_SPD=0.025;
SRCH_SPD_F=0.5;SRCH_ARC_D=20;CORR_BRG_TOL=7.5;CORR_DIST_TOL=150;
ECG_INT_T=45;ECG_RISE_T=5;ECG_FALL_T=8;ECG_ADD_H=10;ECG_W=5;ECG_REST_H=1;
BASE_SWP_S=2; -- Base speed for the sweep line (pixels per tick)
ANIM_SPEED_MULTIPLIER=1.0; -- Multiplier for sweep and ECG animation speed (e.g., 1.0 = normal, 2.0 = double, 0.5 = half). Must be > 0.

-- Inputs
I_SENS_FND=1;I_SENS_D=1;I_SENS_AZ=2;I_SENS_EL=3;
I_BTN_INC_MX=5;I_BTN_DEC_MX=6;I_BTN_LCK=9;I_BTN_DEC_MN=8;I_BTN_PWR=10;
I_RAD_BRG=17;I_SHIP_H=18;

-- Outputs
O_MAX_R=1;O_MIN_R=2;O_RAD_SPD=3;O_W_BRG=4;O_R_BRG=5;O_D1_AZ=6;O_D1_D=7;O_D1_ALT=8;O_D1_EL=9;
O_R_SPAN=10;O_ACT_TRK=11;O_D_RAW_D=12;O_D_MAP_X=13;O_IS_PWR=14;O_ECG_BEAT_OUT=15; -- True when heartbeat peak is active

-- Globals
g_t=0;g_mn_r=MIN_R_MIN;g_mx_r=5000;g_pwr=false;g_nxt_id=1;g_trks={};g_fcs_trk=nil;
g_lck_st=0;g_srch_c_brg=nil;g_srch_dir=1;
g_prv_b={[I_BTN_INC_MX]=false,[I_BTN_DEC_MX]=false,[I_BTN_DEC_MN]=false,[I_BTN_PWR]=false,[I_BTN_LCK]=false}
g_swp_x=MRG;g_d_t1="";g_d_t2="";g_d_t3="";g_d_t4="";

-- Helpers
function d(t)return t*360 end;function r(t)return t*2*math.pi end;function nd(a)a=a%360;if a<0 then a=a+360 end;return a end
function cl(v,mn,mx)return math.max(mn,math.min(v,mx))end;function mpV(v,im,ix,om,ox)if im==ix then return om end;return(v-im)*(ox-om)/(ix-im)+om end
function ad(a1,a2)local df=nd(a1-a2);if df>180 then df=360-df end;return df end

-- Tick
function onTick()
    g_t=g_t+1;local bIncMx=input.getBool(I_BTN_INC_MX);local bDecMx=input.getBool(I_BTN_DEC_MX);local bDecMn=input.getBool(I_BTN_DEC_MN)
    local bLckH=input.getBool(I_BTN_LCK);local bPwrP=input.getBool(I_BTN_PWR)

    local safe_anim_multiplier = math.max(0.01, ANIM_SPEED_MULTIPLIER) -- Avoid division by zero / extreme slow down
    local eff_ecg_int_t_calc = ECG_INT_T / safe_anim_multiplier -- Used for new track init and lbt fallback

    if bPwrP and not g_prv_b[I_BTN_PWR] then g_pwr=not g_pwr;if not g_pwr then g_trks={};g_fcs_trk=nil;g_lck_st=0;g_srch_dir=1;g_d_t2="C:---";g_d_t3="A:---"end end
    g_prv_b[I_BTN_PWR]=bPwrP;output.setBool(O_IS_PWR,g_pwr)
    if bIncMx and not g_prv_b[I_BTN_INC_MX]then g_mx_r=math.min(g_mx_r+R_STEP,MAX_R)end;if bDecMx and not g_prv_b[I_BTN_DEC_MX]then g_mx_r=math.max(g_mx_r-R_STEP,g_mn_r+MIN_R_SPAN)end
    if bDecMn and not g_prv_b[I_BTN_DEC_MN]then g_mn_r=math.max(g_mn_r-R_STEP,MIN_R_MIN);g_mx_r=math.max(g_mx_r,g_mn_r+MIN_R_SPAN)end
    g_prv_b[I_BTN_INC_MX]=bIncMx;g_prv_b[I_BTN_DEC_MX]=bDecMx;g_prv_b[I_BTN_DEC_MN]=bDecMn;g_prv_b[I_BTN_LCK]=bLckH
    
    local cur_fcs_trk_b4_upd=g_fcs_trk -- Store pre-update focused track for lbt comparison
    g_fcs_trk=nil -- Reset focused track for this tick's determination
    local in_bm=false -- Reset in_bm flag

    if not g_pwr then 
        output.setNumber(O_RAD_SPD,0);output.setNumber(O_MAX_R,g_mx_r);output.setNumber(O_MIN_R,g_mn_r);output.setNumber(O_R_SPAN,g_mx_r-g_mn_r)
        output.setNumber(O_ACT_TRK,#g_trks);output.setNumber(O_W_BRG,0);output.setNumber(O_R_BRG,0);output.setNumber(O_D1_AZ,0);output.setNumber(O_D1_D,0)
        output.setNumber(O_D1_ALT,0);output.setNumber(O_D1_EL,0);output.setNumber(O_D_RAW_D,0);output.setNumber(O_D_MAP_X,0)
        output.setBool(O_ECG_BEAT_OUT, false) -- Ensure beat out is false when radar off
        g_d_t1=string.format("OFF R:%d-%d",g_mn_r,g_mx_r);g_d_t2="C:---";g_d_t3="A:---";g_d_t4=string.format("L:%s B:%s P:%s S:%d",bLckH and"T"or"F","F","F",g_lck_st);return 
    end

    local r_brg_t=input.getNumber(I_RAD_BRG);local s_hdg_t=input.getNumber(I_SHIP_H);local r_rel_d=nd(d(r_brg_t));local s_hdg_d=nd(d(s_hdg_t));local r_w_d=nd(s_hdg_d+r_rel_d)
    
    if input.getBool(I_SENS_FND)then local dt_d=input.getNumber(I_SENS_D);local dt_az_t=input.getNumber(I_SENS_AZ);local dt_el_t=input.getNumber(I_SENS_EL)
        if dt_d>0.001 then local dt_w_d=nd(r_w_d+d(dt_az_t));local dt_alt=dt_d*math.tan(r(dt_el_t));local mtch=false
            for i=#g_trks,1,-1 do local trk=g_trks[i]
                if ad(trk.w_brg_d,dt_w_d)<=CORR_BRG_TOL and math.abs(trk.dist-dt_d)<=CORR_DIST_TOL then trk.dist=dt_d;trk.az_rt=dt_az_t;trk.el_rt=dt_el_t
                    trk.w_brg_d=dt_w_d;trk.alt=dt_alt;trk.exp_t=g_t+TRK_LIFE_T;trk.last_upd_t=g_t;mtch=true;break end end
            if not mtch then table.insert(g_trks,{id=g_nxt_id,dist=dt_d,az_rt=dt_az_t,el_rt=dt_el_t,w_brg_d=dt_w_d,alt=dt_alt,exp_t=g_t+TRK_LIFE_T,last_upd_t=g_t,last_beat_trigger_tick=g_t-(eff_ecg_int_t_calc/2)});g_nxt_id=g_nxt_id+1 end end end
    
    local act_trks_tmp={};for i=1,#g_trks do if g_t<g_trks[i].exp_t then table.insert(act_trks_tmp,g_trks[i])end end;g_trks=act_trks_tmp
    
    local f_bm_d=0;local f_bm_x=0;local f_bm_p=false;local d1az,d1d,d1a,d1e=0,0,0,0
    for i=1,#g_trks do local trk=g_trks[i];local in_r=(trk.dist>=g_mn_r and trk.dist<=g_mx_r)
        if in_r then local cur_trk_az_d=ad(trk.w_brg_d,r_w_d);local is_trk_bm=(math.abs(cur_trk_az_d)<=BEAM_W)
            if is_trk_bm then in_bm=true -- Set in_bm flag if any track is in beam
                if not g_fcs_trk then local x=mpV(trk.dist,g_mn_r,g_mx_r,MRG,SCR_W-MRG);x=cl(x,MRG,SCR_W-MRG)
                    local n_alt=cl(trk.alt,0,SRF_ALT_C);local c_pk_h=mpV(n_alt,0,SRF_ALT_C,0,MAX_PK_H);local b_pk_h=math.max(c_pk_h,1.0)
                    local lbt=(trk.last_beat_trigger_tick or(cur_fcs_trk_b4_upd and cur_fcs_trk_b4_upd.id==trk.id and cur_fcs_trk_b4_upd.last_beat_trigger_tick)or(g_t-eff_ecg_int_t_calc))
                    g_fcs_trk={id=trk.id,x_pos=x,base_h=b_pk_h,last_beat_trigger_tick=lbt,dist=trk.dist,alt=trk.alt,el_rt=trk.el_rt,trk_az_rad_d=cur_trk_az_d}
                    -- trk.last_beat_trigger_tick is already part of the main trk object, lbt is used to initialize g_fcs_trk's copy
                    f_bm_d=trk.dist;f_bm_x=x;g_d_t2=string.format("C%d D:%.1f Az:%.1f El:%.2f",trk.id,trk.dist,cur_trk_az_d,trk.el_rt)
                    g_d_t3=string.format("C%d A:%.1f X:%.0f H:%.1f",trk.id,trk.alt,x,b_pk_h);d1az=cur_trk_az_d;d1d=trk.dist;d1a=trk.alt;d1e=trk.el_rt;f_bm_p=true end end end end
    
    if not f_bm_p then g_d_t2="C-:---";g_d_t3="A-:---"end
    output.setNumber(O_D1_AZ,d1az);output.setNumber(O_D1_D,d1d);output.setNumber(O_D1_ALT,d1a);output.setNumber(O_D1_EL,d1e)
    output.setNumber(O_D_RAW_D,f_bm_d);output.setNumber(O_D_MAP_X,f_bm_x)
    
    -- Heartbeat Output Logic (moved to onTick)
    if g_fcs_trk then
        local eff_ecg_int_t = ECG_INT_T / safe_anim_multiplier
        local eff_ecg_rise_t = ECG_RISE_T / safe_anim_multiplier
        local eff_ecg_fall_t = ECG_FALL_T / safe_anim_multiplier

        -- Update heartbeat trigger tick if interval has passed for the focused track
        if g_t - g_fcs_trk.last_beat_trigger_tick >= eff_ecg_int_t then
            g_fcs_trk.last_beat_trigger_tick = g_t
            -- Also update this in the main g_trks list for consistency
            for i = 1, #g_trks do
                if g_trks[i].id == g_fcs_trk.id then
                    g_trks[i].last_beat_trigger_tick = g_t
                    break
                end
            end
        end

        local el_b = g_t - g_fcs_trk.last_beat_trigger_tick
        local is_beat_active = (el_b >= 0 and el_b < eff_ecg_rise_t + eff_ecg_fall_t)
        output.setBool(O_ECG_BEAT_OUT, is_beat_active)
    else
        output.setBool(O_ECG_BEAT_OUT, false)
    end
    
    local d_spd=DEF_SPD
    if bLckH then
        if in_bm then -- Use the in_bm flag determined during g_fcs_trk search
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
    output.setNumber(O_RAD_SPD,d_spd)

    g_d_t1=string.format("Trk:%d Fcs:%s Swp:%.0f R:%d-%d",#g_trks,g_fcs_trk and"T"or"F",g_swp_x,g_mn_r,g_mx_r)
    g_d_t4=string.format("L:%s B:%s P:%s S:%d",bLckH and"T"or"F",in_bm and"T"or"F",g_pwr and"T"or"F",g_lck_st) -- Use in_bm flag here
    output.setNumber(O_MAX_R,g_mx_r);output.setNumber(O_MIN_R,g_mn_r);output.setNumber(O_W_BRG,r_w_d);output.setNumber(O_R_BRG,r_rel_d)
    output.setNumber(O_R_SPAN,g_mx_r-g_mn_r);output.setNumber(O_ACT_TRK,#g_trks)
end

-- Draw
function onDraw()
    -- O_ECG_BEAT_OUT is now set in onTick

    if not g_pwr then screen.setColor(100,100,100,255);screen.drawClear();screen.drawText(SCR_W/2-20,SCR_H/2-3,"RADAR OFF")
        screen.setColor(200,200,200,150);screen.drawText(MRG,SCR_H-8,string.format("%.0f",g_mn_r));local m_r_txt=string.format("%.0f",g_mx_r)
        local t_w=string.len(m_r_txt)*4;screen.drawText(SCR_W-MRG-t_w,SCR_H-8,m_r_txt);screen.setColor(255,255,0,255);screen.drawText(1,19,g_d_t4);return end
    
    local safe_anim_multiplier = math.max(0.01, ANIM_SPEED_MULTIPLIER) 
    local actual_sweep_increment = BASE_SWP_S * safe_anim_multiplier
    
    screen.setColor(0,255,0,255)
    g_swp_x = g_swp_x + actual_sweep_increment
    if g_swp_x > (SCR_W - MRG + actual_sweep_increment / 2) then g_swp_x = MRG end 
    local cur_swp_x = cl(g_swp_x, MRG, SCR_W - MRG)
    
    screen.drawLine(MRG,BASE_Y,cur_swp_x,BASE_Y);screen.drawLine(MRG,BASE_Y-2,MRG,BASE_Y+2)
    if cur_swp_x >= SCR_W-MRG then screen.drawLine(SCR_W-MRG,BASE_Y-2,SCR_W-MRG,BASE_Y+2)end
    
    if g_fcs_trk then 
        local ft = g_fcs_trk -- ft.last_beat_trigger_tick is now managed by onTick
        
        -- Effective ECG timings for drawing visuals
        local eff_ecg_rise_t_draw = ECG_RISE_T / safe_anim_multiplier
        local eff_ecg_fall_t_draw = ECG_FALL_T / safe_anim_multiplier
        
        local el_b = g_t - ft.last_beat_trigger_tick -- Use the tick value from onTick
        local pk_h = ECG_REST_H
        
        if el_b < eff_ecg_rise_t_draw then 
            local p = el_b / eff_ecg_rise_t_draw
            pk_h = ECG_REST_H + p * (ft.base_h + ECG_ADD_H - ECG_REST_H)
        elseif el_b < eff_ecg_rise_t_draw + eff_ecg_fall_t_draw then 
            local pf = (el_b - eff_ecg_rise_t_draw) / eff_ecg_fall_t_draw
            pk_h = (ft.base_h + ECG_ADD_H) - pf * (ft.base_h + ECG_ADD_H - ECG_REST_H)
        end
        -- No output.setBool here anymore
        
        pk_h = cl(pk_h, ECG_REST_H, MAX_PK_H)
        local xc = ft.x_pos
        local xl = cl(xc - ECG_W / 2, MRG, SCR_W - MRG - 1)
        local xr = cl(xc + ECG_W / 2, MRG, SCR_W - MRG - 1)
        local yt = cl(BASE_Y - pk_h, 0, SCR_H - 1)
        
        if pk_h > ECG_REST_H then 
             screen.drawLine(xl, BASE_Y, xc, yt)
             screen.drawLine(xc, yt, xr, BASE_Y)
        end
    end
    
    screen.setColor(255,255,0,255);screen.drawText(1,1,g_d_t1);screen.drawText(1,7,g_d_t2);screen.drawText(1,13,g_d_t3);screen.drawText(1,19,g_d_t4)
    screen.setColor(200,200,200,150);screen.drawText(MRG,SCR_H-8,string.format("%.0f",g_mn_r));local m_r_txt=string.format("%.0f",g_mx_r)
    local t_w=string.len(m_r_txt)*4;screen.drawText(SCR_W-MRG-t_w,SCR_H-8,m_r_txt)
end