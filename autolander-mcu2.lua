--[[
Aircraft Autoland System - MCU 2: Calculation Engine
Version 2.0 (Split Architecture) - Shortened variable and constant names.
                                  IAF calculation based on state from MCU1.
                                  Includes IAF debug outputs.
                                  Compatible with MCU 1 v2.2.
]]

---------------------------------------------------------------------
-- MCU 2 - INPUT CHANNEL MAPPING (From MCU 1 - 19 Total Inputs)
---------------------------------------------------------------------
M1_STATE_IN = 1; M1_AC_X_IN = 2; M1_AC_Y_IN = 3; M1_AC_ALT_REL_IN = 4; 
M1_AC_HDG_IN = 5; M1_AC_SPD_IN = 6; M1_AC_PIT_IN = 7; M1_AC_ROL_IN = 8;     
M1_C_X_IN = 9; M1_C_Y_IN = 10; M1_C_ALT_IN = 11; M1_C_HDG_IN = 12;
M1_C_SPD_IN = 13; M1_TGT_P1_IN = 14; M1_TGT_P2_IN = 15; M1_TGT_P3_IN = 16; 
M1_TGT_P4_IN = 17; M1_IAF_TRIG_IN = 18; M1_DIST_C_IN = 19;
---------------------------------------------------------------------
-- MCU 2 - OUTPUT CHANNEL MAPPING (To MCU 1 - 10 Total Outputs)
---------------------------------------------------------------------
OUT_M1_THR = 1; OUT_M1_PIT = 2; OUT_M1_ROL = 3; OUT_M1_YAW = 4;
OUT_M1_DBG_WPX = 5; OUT_M1_DBG_WPY = 6; 
OUT_M1_DBG_C_X = 7; OUT_M1_DBG_C_Y = 8; 
OUT_M1_DBG_C_HDG = 9; OUT_M1_DBG_IAF_DIST = 10; 
---------------------------------------------------------------------

-- Input/Output Aliases
local igN = input.getNumber; local igB = input.getBool; 
local isN = output.setNumber; local isB = output.setBool; 

-- Constants
RAD_TO_DEG = 180/math.pi; DEG_TO_RAD = math.pi/180; DT = 1/60;

-- Autoland States (Consistent with MCU1 v2.2)
ST_IDLE=0;ST_REQ_IAF=1;ST_NAV_IAF=2;ST_ALIGN=3;ST_GS_ESTAB=4;ST_ON_GS=5;ST_FLARE=6;ST_TD_AWAIT=7;ST_LANDED=8;ST_ABORT=9;
-- ST_WAIT_IAF = 10; -- This state is internal to MCU1, MCU2 sees ST_REQ_IAF during this time.


-- PID Controllers Data
pidAir={Kp=0.8,Ki=0.2,Kd=0.1,I=0,pE=0,min=-1,max=1};
pidAlt={Kp=0.7,Ki=0.15,Kd=0.1,I=0,pE=0,min=-1,max=1};
pidGsPit={Kp=0.9,Ki=0.2,Kd=0.15,I=0,pE=0,min=-1,max=1};
pidRolHdg={Kp=1.0,Ki=0.1,Kd=0.2,I=0,pE=0,min=-1,max=1};
pidYawCoord={Kp=0.5,Ki=0.05,Kd=0.05,I=0,pE=0,min=-1,max=1};

iafXCalc=0;iafYCalc=0; 

function cl(v,mn,mx)return math.max(mn,math.min(mx,v))end
function d2r(d)return d*DEG_TO_RAD end; function r2d(r)return r*RAD_TO_DEG end
function normAng(a)a=a%360;if a<0 then a=a+360 end;return a end
function dist2d(x1,y1,x2,y2)if x1==nil or y1==nil or x2==nil or y2==nil then return 99999 end return math.sqrt((x2-x1)^2+(y2-y1)^2)end
function bearingTo(cx,cy,tx,ty)if cx==nil or cy==nil or tx==nil or ty==nil then return 0 end return normAng(r2d(math.atan2(tx-cx,ty-cy)))end
function ptAstern(cx,cy,chg,d)if cx==nil or cy==nil or chg==nil or d==nil or d==0 then return cx or 0,cy or 0 end local hr=d2r(chg);return cx-d*math.sin(hr),cy-d*math.cos(hr)end
function pidUpd(p,s,pv,dt)if s==nil or pv==nil then return 0 end local e=s-pv;p.I=cl(p.I+e*dt,-3,3);local drv=0;if dt>0 then drv=(e-p.pE)/dt end;p.pE=e;return cl(p.Kp*e+p.Ki*p.I+p.Kd*drv,p.min,p.max)end
function pidsRst()pidAir.I=0;pidAir.pE=0;pidAlt.I=0;pidAlt.pE=0;pidGsPit.I=0;pidGsPit.pE=0;pidRolHdg.I=0;pidRolHdg.pE=0;pidYawCoord.I=0;pidYawCoord.pE=0;end

function onTick()
    local m1State=igN(M1_STATE_IN);local acX=igN(M1_AC_X_IN);local acY=igN(M1_AC_Y_IN);local acAltRel=igN(M1_AC_ALT_REL_IN);local acHdg=igN(M1_AC_HDG_IN);local acSpd=igN(M1_AC_SPD_IN);local acPit=igN(M1_AC_PIT_IN);local acRol=igN(M1_AC_ROL_IN);local cX=igN(M1_C_X_IN);local cY=igN(M1_C_Y_IN);local cAlt=igN(M1_C_ALT_IN);local cHdg=igN(M1_C_HDG_IN);local cSpd=igN(M1_C_SPD_IN);
    local tP1=igN(M1_TGT_P1_IN);local tP2=igN(M1_TGT_P2_IN);local tP3=igN(M1_TGT_P3_IN);local tP4=igN(M1_TGT_P4_IN);
    -- local iafTrig=igN(M1_IAF_TRIG_IN)>0.5; -- Not directly used for calculation trigger anymore
    local distToC=igN(M1_DIST_C_IN);

    local cmdThr=0;local cmdPit=0;local cmdRol=0;local cmdYaw=0;
    local dbgWpX=0; local dbgWpY=0; -- Initialize to 0 to ensure they are explicitly set
    local dbgRxCX=0;local dbgRxCY=0;local dbgRxCHdg=0;local dbgRxIafD=0;

    if m1State==ST_IDLE or m1State==ST_LANDED then 
        pidsRst();iafXCalc=0;iafYCalc=0;
        if m1State==ST_LANDED then cmdThr=-1.0 end;
        dbgWpX=acX; dbgWpY=acY; -- Default to AC position when idle/landed
    
    elseif m1State==ST_REQ_IAF then -- MCU1 sends this state when it wants IAF calculated (during its ST_REQ_IAF and ST_WAIT_IAF)
        dbgRxCX=cX; dbgRxCY=cY; 
        dbgRxCHdg=cHdg; dbgRxIafD=tP1;
        local iafD=tP1; -- tP1 from MCU1 is IAF_DIST_ASTERN
        iafXCalc,iafYCalc=ptAstern(cX,cY,cHdg,iafD);
        dbgWpX=iafXCalc; 
        dbgWpY=iafYCalc;
        -- No flight control commands from MCU2 in this state, just calculate IAF and send it back.
    
    elseif m1State==ST_NAV_IAF then 
        local tx=tP1;local ty=tP2;local tAlt=tP3;local tSpd=tP4;
        dbgWpX=tx;dbgWpY=ty; -- In this state, tP1/tP2 are the actual IAF coords from MCU1
        local brg=bearingTo(acX,acY,tx,ty);
        local hErr=normAng(brg-acHdg);if hErr>180 then hErr=hErr-360 end;
        cmdRol=pidUpd(pidRolHdg,0,-hErr,DT);
        cmdPit=pidUpd(pidAlt,tAlt,acAltRel,DT);
        cmdThr=pidUpd(pidAir,tSpd,acSpd,DT);
    
    elseif m1State==ST_ALIGN then 
        local tSpd=tP1;local tAlt=tP2;local mBank=tP3;
        local alX,alY=ptAstern(cX,cY,cHdg,2000);
        dbgWpX=alX;dbgWpY=alY;
        local brg=bearingTo(acX,acY,alX,alY);
        local hErr=normAng(brg-acHdg);if hErr>180 then hErr=hErr-360 end;
        cmdRol=pidUpd(pidRolHdg,0,-hErr,DT);cmdRol=cl(cmdRol,-mBank/90,mBank/90);
        cmdPit=pidUpd(pidAlt,tAlt,acAltRel,DT);
        cmdThr=pidUpd(pidAir,tSpd,acSpd,DT);
    
    elseif m1State==ST_GS_ESTAB or m1State==ST_ON_GS then 
        local tSpd=tP1;local tGs=tP2;local mBank=0;if m1State==ST_ON_GS then mBank=tP4 end;
        local latErr=normAng(cHdg-acHdg);if latErr>180 then latErr=latErr-360 end;
        cmdRol=pidUpd(pidRolHdg,0,-latErr,DT);if mBank~=0 then cmdRol=cl(cmdRol,-mBank/90,mBank/90)end;
        local idealH=distToC*math.tan(d2r(tGs));
        -- Check if acAltRel is radar alt by comparing with the input channel number MCU1 uses for radar
        -- This is an indirect check. MCU1 sends its AC_RADAR_ALT on its M1_AC_ALT_REL output (Ch 13)
        -- MCU2 receives this on its FROM_MCU1_AC_ALT_REL input (Ch 4)
        if acAltRel == igN(4) and distToC > 10 then -- If value on Ch4 is what MCU1 read from its radar sensor
            cmdPit=pidUpd(pidGsPit,idealH,acAltRel,DT)
        else 
            cmdPit=pidUpd(pidAlt,cAlt+idealH,acAltRel,DT)
        end;
        cmdThr=pidUpd(pidAir,tSpd,acSpd,DT);
        dbgWpX=cX;dbgWpY=cY;
    
    elseif m1State==ST_FLARE then 
        local tSpd=tP1;local tPit=tP2;local mBank=tP3;local flareH=tP4;
        local latErr=normAng(cHdg-acHdg);if latErr>180 then latErr=latErr-360 end;
        cmdRol=pidUpd(pidRolHdg,0,-latErr,DT);cmdRol=cl(cmdRol,-mBank/90,mBank/90);
        cmdPit=pidUpd(pidGsPit,tPit,acPit,DT);
        cmdThr=pidUpd(pidAir,tSpd,acSpd,DT);
        if acAltRel<(flareH/2)and acAltRel>0.1 then cmdThr=cl(cmdThr-0.5,-1,1)end;
        dbgWpX=cX;dbgWpY=cY;
    
    elseif m1State==ST_TD_AWAIT then 
        local tThr=tP1;local tPit=tP2;
        cmdThr=tThr;cmdPit=pidUpd(pidGsPit,tPit,acPit,DT);cmdRol=0;
        dbgWpX=cX;dbgWpY=cY;
    
    elseif m1State==ST_ABORT then 
        local tThr=tP1;local tPitAtt=tP2;
        cmdThr=tThr;cmdPit=pidUpd(pidAlt,tPitAtt,acPit,DT);cmdRol=0;
    end

    if math.abs(acRol)>2.0 then 
        cmdYaw=pidUpd(pidYawCoord,0,acRol*0.05,DT)
    else 
        cmdYaw=0 
    end;

    isN(OUT_M1_THR,cmdThr);isN(OUT_M1_PIT,cmdPit);isN(OUT_M1_ROL,cmdRol);isN(OUT_M1_YAW,cmdYaw);
    isN(OUT_M1_DBG_WPX,dbgWpX);isN(OUT_M1_DBG_WPY,dbgWpY);
    isN(OUT_M1_DBG_C_X,dbgRxCX);isN(OUT_M1_DBG_C_Y,dbgRxCY);isN(OUT_M1_DBG_C_HDG,dbgRxCHdg);isN(OUT_M1_DBG_IAF_DIST,dbgRxIafD);
end
