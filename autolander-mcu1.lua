--[[
Aircraft Autoland System - MCU 1: Core Controller
Version 2.2 (Split Architecture) - Shortened variable and constant names.
                                  Focused debug on data sent to MCU2 for IAF calculation.
                                  Implements IAF handshake.
                                  Ensured channel compliance (max 32 in/out).
                                  Uses IO Aliases.
                                  Includes tilt sensor "turns" to "degrees" conversion.
]]

---------------------------------------------------------------------
-- MCU 1 - INPUT CHANNEL MAPPING (32 Total Inputs)
---------------------------------------------------------------------
C_X = 1; C_Y = 2; C_ALT_IN = 3; C_HDG_N = 4; C_SPD = 5; -- Carrier Data
AC_X = 6; AC_Y = 7; AC_BARO_A = 8; AC_HDG = 9; AC_SPD_MPS = 10; -- Aircraft Sensors
AC_PIT_T = 11; AC_ROL_T = 12; AC_RADAR_A = 13; AC_WIND_DIR = 14;
AC_WIND_SPD = 15; AC_HOOK = 16; ENGAGE_AL = 17; RECALC_IAF = 18; -- Aircraft Sensors & User Controls
TGT_AP_SPD = 19; TGT_GS_DEG_IN = 20; IAF_DIST_A = 21; IAF_ALT_OFF = 22; -- User Properties
FLARE_H = 23; MAX_BANK = 24; TGT_TD_PIT_IN = 25; RADAR_INV = 26; -- User Properties
M2_THR = 27; M2_PIT = 28; M2_ROL = 29; M2_YAW = 30; -- From MCU2
M2_DBG_WPX = 31; M2_DBG_WPY = 32; -- From MCU2
---------------------------------------------------------------------
-- MCU 1 - OUTPUT CHANNEL MAPPING (32 Total Outputs)
---------------------------------------------------------------------
OUT_THR = 1; OUT_PIT = 2; OUT_ROL = 3; OUT_YAW = 4; -- To Aircraft Controls
OUT_WPX = 5; OUT_WPY = 6; OUT_WPALT = 7; OUT_HOOK = 8; OUT_LIGHT = 9; -- To Aircraft Displays/Actuators
M1_STATE = 10; M1_AC_X = 11; M1_AC_Y = 12; M1_AC_ALT_REL = 13; -- To MCU2
M1_AC_HDG = 14; M1_AC_SPD = 15; M1_AC_PIT = 16; M1_AC_ROL = 17; -- To MCU2
M1_C_X = 18; M1_C_Y = 19; M1_C_ALT = 20; M1_C_HDG = 21; -- To MCU2
M1_C_SPD = 22; M1_TGT_P1 = 23; M1_TGT_P2 = 24; M1_TGT_P3 = 25; -- To MCU2
M1_TGT_P4 = 26; M1_IAF_TRIG = 27; M1_DIST_C = 28; -- To MCU2
DBG_M1_STATE = 29; DBG_M1_ENGAGE = 30; DBG_M1_LAST_ENG = 31; -- MCU1 Debug
DBG_M1_IAF_DIST = 32; -- MCU1 Debug
---------------------------------------------------------------------

local igN = input.getNumber; local igB = input.getBool; local pgN = property.getNumber; 
local isN = output.setNumber; local isB = output.setBool;

STATE_IDLE=0;ST_REQ_IAF=1;ST_NAV_IAF=2;ST_ALIGN=3;ST_GS_ESTAB=4;ST_ON_GS=5;ST_FLARE=6;ST_TD_AWAIT=7;ST_LANDED=8;ST_ABORT=9;ST_WAIT_IAF=10;
cur_state=STATE_IDLE;iafX=0;iafY=0;iafAlt=0;deckDetect=false;recalcBtnPrev=false;lastEngage=false;abortRsn="";tdTimer=0;deckLossTmr=0;awaitIAFTmr=0;
function d2r(d) return d*(math.pi/180) end
function dist2d(x1,y1,x2,y2) return math.sqrt((x2-x1)^2+(y2-y1)^2) end

function onTick()
    local cX=igN(C_X);local cY=igN(C_Y);local cAlt=igN(C_ALT_IN);local cHdgN=igN(C_HDG_N);local cSpd=igN(C_SPD);local cHdg=cHdgN*360;
    local acX=igN(AC_X);local acY=igN(AC_Y);local acBaroA=igN(AC_BARO_A);local acHdg=igN(AC_HDG);local acSpd=igN(AC_SPD_MPS);
    local acPitT=igN(AC_PIT_T);local acRolT=igN(AC_ROL_T);local acPit=acPitT*360;local acRol=acRolT*360;
    local acRadarA=igN(AC_RADAR_ALT);local hooked=igB(AC_HOOK);
    local engage=igB(ENGAGE_AL);local recalcBtn=igB(RECALC_IAF);
    local tgtApSpd=igN(TGT_AP_SPD);local tgtGsDeg=igN(TGT_GS_DEG_IN);local iafDistA=igN(IAF_DIST_A);local iafAltOff=igN(IAF_ALT_OFF);
    local flareH=igN(FLARE_H);local maxBank=igN(MAX_BANK);local tgtTdPit=igN(TGT_TD_PIT_IN);local radarInv=igN(RADAR_INV);
    local m2Thr=igN(M2_THR);local m2Pit=igN(M2_PIT);local m2Rol=igN(M2_ROL);local m2Yaw=igN(M2_YAW);
    local m2WpX=igN(M2_DBG_WPX);local m2WpY=igN(M2_DBG_WPY);

    local recalcEdge=false; if recalcBtn and not recalcBtnPrev then recalcEdge=true end; recalcBtnPrev=recalcBtn;
    if engage and not lastEngage then if cur_state==STATE_IDLE then cur_state=ST_REQ_IAF;recalcEdge=true;abortRsn="Eng" else cur_state=STATE_IDLE;abortRsn="Diseng" end end; lastEngage=engage;
    if recalcEdge and cur_state~=STATE_IDLE and cur_state~=ST_REQ_IAF then cur_state=ST_REQ_IAF;abortRsn="Recalc";end
    local plausibleMaxRadarH=iafAltOff+cAlt+50; if acRadarA~=radarInv and acRadarA>0.1 and acRadarA<plausibleMaxRadarH then if math.abs(acBaroA-(cAlt+acRadarA))<75 then deckDetect=true;deckLossTmr=0 else deckDetect=false end else deckDetect=false end;
    if not deckDetect and(cur_state==ST_ON_GS or cur_state==ST_FLARE or cur_state==ST_TD_AWAIT)then deckLossTmr=deckLossTmr+(1/60) else deckLossTmr=0 end;
    local cmdThr=0;local cmdPit=0;local cmdRol=0;local cmdYaw=0;local cmdHook=false;local cmdLight=false;
    local distToC=dist2d(acX,acY,cX,cY);
    local m2AcAltRel=acBaroA;local m2TgtP1=0;local m2TgtP2=0;local m2TgtP3=0;local m2TgtP4=0;local m2IafTrig=0.0;
    local sentCXDbg=0;local sentCYDbg=0;local sentIafDistDbg=0;

    if cur_state==STATE_IDLE then cmdLight=false;cmdHook=false;tdTimer=0;deckLossTmr=0;awaitIAFTmr=0;
    elseif cur_state==ST_REQ_IAF then cmdLight=true;m2IafTrig=1.0;m2TgtP1=iafDistA;m2TgtP2=iafAltOff;iafAlt=cAlt+iafAltOff;cur_state=ST_WAIT_IAF;abortRsn="IAF Req";awaitIAFTmr=0;recalcEdge=false;sentCXDbg=cX;sentCYDbg=cY;sentIafDistDbg=iafDistA;
    elseif cur_state==ST_WAIT_IAF then cmdLight=true;awaitIAFTmr=awaitIAFTmr+(1/60);sentCXDbg=cX;sentCYDbg=cY;sentIafDistDbg=iafDistA;if m2WpX~=0 or m2WpY~=0 then iafX=m2WpX;iafY=m2WpY;cur_state=ST_NAV_IAF;abortRsn="IAF Rcvd";elseif awaitIAFTmr>2.0 then cur_state=ST_ABORT;abortRsn="IAF Timeout";else m2_request_state_signal=ST_REQ_IAF;m2IafTrig=0.0;m2TgtP1=iafDistA;m2TgtP2=iafAltOff;end
    elseif cur_state==ST_NAV_IAF then cmdLight=true;m2TgtP1=iafX;m2TgtP2=iafY;m2TgtP3=iafAlt;m2TgtP4=tgtApSpd+15;if dist2d(acX,acY,iafX,iafY)<500 and(iafX~=0 or iafY~=0)then cur_state=ST_ALIGN;abortRsn="IAF Ok"end;
    elseif cur_state==ST_ALIGN then cmdLight=true;cmdHook=true;m2AcAltRel=acBaroA;m2TgtP1=tgtApSpd;m2TgtP2=cAlt+iafAltOff;m2TgtP3=maxBank;local angDiff=math.abs(acHdg-cHdg);if angDiff>180 then angDiff=360-angDiff end;if angDiff<15 and distToC<(iafDistA*0.8)and distToC>2000 then cur_state=ST_GS_ESTAB;abortRsn="Align Ok"end;if distToC<1500 then cur_state=ST_ABORT;abortRsn="Close Align";end
    elseif cur_state==ST_GS_ESTAB then cmdLight=true;cmdHook=true;if deckDetect then m2AcAltRel=acRadarA else m2AcAltRel=acBaroA end;m2TgtP1=tgtApSpd;m2TgtP2=tgtGsDeg;m2TgtP3=maxBank;if deckDetect and deckLossTmr==0 then cur_state=ST_ON_GS;abortRsn="GS Ok (R)"end;if not deckDetect and distToC<1500 and deckLossTmr>3.0 then cur_state=ST_ABORT;abortRsn="No Radar GS"end
    elseif cur_state==ST_ON_GS then cmdLight=true;cmdHook=true;if not deckDetect then if deckLossTmr>1.0 then cur_state=ST_ABORT;abortRsn="Lost GS";end else m2AcAltRel=acRadarA end;m2TgtP1=tgtApSpd;m2TgtP2=tgtGsDeg;m2TgtP3=flareH;m2TgtP4=maxBank;if acRadarA<=flareH and deckDetect then cur_state=ST_FLARE;abortRsn="Flare H"end;if distToC<50 and acRadarA>flareH then cur_state=ST_ABORT;abortRsn="Miss Flare"end
    elseif cur_state==ST_FLARE then cmdLight=true;cmdHook=true;if not deckDetect then if deckLossTmr>0.5 then cur_state=ST_ABORT;abortRsn="Lost Flare";end else m2AcAltRel=acRadarA end;m2TgtP1=tgtApSpd-5;m2TgtP2=tgtTdPit;m2TgtP3=maxBank;m2TgtP4=flareH;if acRadarA<1.0 and deckDetect then cur_state=ST_TD_AWAIT;abortRsn="Await TD";tdTimer=0;end;if acRadarA>flareH*1.5 then cur_state=ST_ABORT;abortRsn="Balloon";end
    elseif cur_state==ST_TD_AWAIT then cmdLight=true;cmdHook=true;tdTimer=tdTimer+(1/60);if not deckDetect and acRadarA>2.0 then if deckLossTmr>0.5 then cur_state=ST_ABORT;abortRsn="Lost TD/Bounce";end else m2AcAltRel=acRadarA end;m2TgtP1=-1.0;m2TgtP2=tgtTdPit;if hooked then cur_state=ST_LANDED;abortRsn="Hooked!";end;if tdTimer>4.0 then cur_state=ST_ABORT;abortRsn="Bolter";end
    elseif cur_state==ST_LANDED then cmdLight=false;cmdHook=true;m2TgtP1=-1.0;tdTimer=0;deckLossTmr=0;
    elseif cur_state==ST_ABORT then cmdLight=true;cmdHook=false;m2TgtP1=1.0;m2TgtP2=acPit+10;m2AcAltRel=acBaroA+200;tdTimer=0;deckLossTmr=0;if acBaroA>(cAlt+iafAltOff+100)then end
    end

    if cur_state~=STATE_IDLE then cmdThr=m2Thr;cmdPit=m2Pit;cmdRol=m2Rol;cmdYaw=m2Yaw;end;
    isN(OUT_THR,cmdThr);isN(OUT_PIT,cmdPit);isN(OUT_ROL,cmdRol);isN(OUT_YAW,cmdYaw);
    isN(OUT_WPX,m2WpX);isN(OUT_WPY,m2WpY);isN(OUT_WPALT,iafAlt);
    isB(OUT_HOOK,cmdHook);isB(OUT_LIGHT,cmdLight);
    local m1StateToSend=cur_state;if cur_state==ST_WAIT_IAF then m1StateToSend=ST_REQ_IAF end;isN(M1_STATE,m1StateToSend);
    isN(M1_AC_X,acX);isN(M1_AC_Y,acY);isN(M1_AC_ALT_REL,m2AcAltRel);isN(M1_AC_HDG,acHdg);isN(M1_AC_SPD,acSpd);isN(M1_AC_PIT,acPit);isN(M1_AC_ROL,acRol);
    isN(M1_C_X,cX);isN(M1_C_Y,cY);isN(M1_C_ALT,cAlt);isN(M1_C_HDG,cHdg);isN(M1_C_SPD,cSpd);
    isN(M1_TGT_P1,m2TgtP1);isN(M1_TGT_P2,m2TgtP2);isN(M1_TGT_P3,m2TgtP3);isN(M1_TGT_P4,m2TgtP4);
    isN(M1_IAF_TRIG,m2IafTrig);isN(M1_DIST_C,distToC);
    isN(DBG_M1_STATE,cur_state);
    if cur_state==ST_REQ_IAF or cur_state==ST_WAIT_IAF then isN(SENT_C_X_TO_MCU2,cX);isN(SENT_C_Y_TO_MCU2,cY);isN(SENT_IAF_DIST_TO_MCU2,iafDistA);
    else isN(SENT_C_X_TO_MCU2,0);isN(SENT_C_Y_TO_MCU2,0);isN(SENT_IAF_DIST_TO_MCU2,0);end
end
