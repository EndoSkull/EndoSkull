--[[
Aircraft Autoland System - MCU 1: Core Controller
Version 2.4 (Split Architecture) - Corrected logic for debug outputs SENT_C_X/Y_TO_MCU2 and SENT_IAF_DIST_TO_MCU2.
                                  Added numerical abort reason code for debugging.
                                  Implements IAF handshake. Shortened names. IO Aliases. Tilt conversion.
]]

---------------------------------------------------------------------
-- MCU 1 - INPUT CHANNEL MAPPING (32 Total Inputs)
---------------------------------------------------------------------
C_X = 1; C_Y = 2; C_ALT_IN = 3; C_HDG_N = 4; C_SPD = 5; 
AC_X = 6; AC_Y = 7; AC_BARO_A = 8; AC_HDG = 9; AC_SPD_MPS = 10; 
AC_PIT_T = 11; AC_ROL_T = 12; AC_RADAR_A = 13; AC_WIND_DIR = 14;
AC_WIND_SPD = 15; AC_HOOK = 16; ENGAGE_AL = 17; RECALC_IAF = 18; 
TGT_AP_SPD = 19; TGT_GS_DEG_IN = 20; IAF_DIST_A = 21; IAF_ALT_OFF = 22; 
FLARE_H = 23; MAX_BANK = 24; TGT_TD_PIT_IN = 25; RADAR_INV = 26; 
M2_THR = 27; M2_PIT = 28; M2_ROL = 29; M2_YAW = 30; 
M2_DBG_WPX = 31; M2_DBG_WPY = 32; 
---------------------------------------------------------------------
-- MCU 1 - OUTPUT CHANNEL MAPPING (32 Total Outputs)
---------------------------------------------------------------------
OUT_THR = 1; OUT_PIT = 2; OUT_ROL = 3; OUT_YAW = 4; 
OUT_WPX = 5; OUT_WPY = 6; OUT_WPALT = 7; OUT_HOOK = 8; OUT_LIGHT = 9; 
M1_STATE = 10; M1_AC_X = 11; M1_AC_Y = 12; M1_AC_ALT_REL = 13; 
M1_AC_HDG = 14; M1_AC_SPD = 15; M1_AC_PIT = 16; M1_AC_ROL = 17; 
M1_C_X = 18; M1_C_Y = 19; M1_C_ALT = 20; M1_C_HDG = 21; 
M1_C_SPD = 22; M1_TGT_P1 = 23; M1_TGT_P2 = 24; M1_TGT_P3 = 25; 
M1_TGT_P4 = 26; M1_IAF_TRIG = 27; M1_DIST_C = 28; 
DBG_M1_STATE = 29; 
DBG_ABORT_CODE = 30; 
DBG_AWAIT_TMR = 31;  
DBG_TD_TMR = 32;         
---------------------------------------------------------------------

local igN = input.getNumber; local igB = input.getBool; local pgN = property.getNumber; 
local isN = output.setNumber; local isB = output.setBool;

STATE_IDLE=0;ST_REQ_IAF=1;ST_NAV_IAF=2;ST_ALIGN=3;ST_GS_ESTAB=4;ST_ON_GS=5;ST_FLARE=6;ST_TD_AWAIT=7;ST_LANDED=8;ST_ABORT=9;ST_WAIT_IAF=10;
cur_state=STATE_IDLE;iafX=0;iafY=0;iafAlt=0;deckDetect=false;recalcBtnPrev=false;lastEngage=false;abortRsn="";tdTimer=0;deckLossTmr=0;awaitIAFTmr=0;
local dbgAbortCodeNum = 0; 

ABORT_CODE_NONE=0;ABORT_CODE_IAF_TIMEOUT=1;ABORT_CODE_TOO_CLOSE_ALIGN=2;ABORT_CODE_NO_RADAR_GS=3;ABORT_CODE_LOST_RADAR_GS=4;ABORT_CODE_MISSED_FLARE=5;ABORT_CODE_LOST_RADAR_FLARE=6;ABORT_CODE_BALLOONED=7;ABORT_CODE_LOST_DECK_BOUNCE=8;ABORT_CODE_BOLTER_TIMEOUT=9;

function d2r(d) return d*(math.pi/180) end
function dist2d(x1,y1,x2,y2) return math.sqrt((x2-x1)^2+(y2-y1)^2) end
function setAbort(rsnTxt, rsnCode) cur_state=ST_ABORT;abortRsn=rsnTxt;dbgAbortCodeNum=rsnCode;end

function onTick()
    local cXVal=igN(C_X);local cYVal=igN(C_Y);local cAltVal=igN(C_ALT_IN);local cHdgNVal=igN(C_HDG_N);local cSpdVal=igN(C_SPD);local cHdgVal=cHdgNVal*360;
    local acXVal=igN(AC_X);local acYVal=igN(AC_Y);local acBaroAVal=igN(AC_BARO_A);local acHdgVal=igN(AC_HDG);local acSpdVal=igN(AC_SPD_MPS);
    local acPitTVal=igN(AC_PIT_T);local acRolTVal=igN(AC_ROL_T);local acPitVal=acPitTVal*360;local acRolVal=acRolTVal*360;
    local acRadarAVal=igN(AC_RADAR_A);local hookedVal=igB(AC_HOOK);
    local engageVal=igB(ENGAGE_AL);local recalcBtnVal=igB(RECALC_IAF);
    local tgtApSpdVal=igN(TGT_AP_SPD);local tgtGsDegVal=igN(TGT_GS_DEG_IN);local iafDistAVal=igN(IAF_DIST_A);local iafAltOffVal=igN(IAF_ALT_OFF);
    local flareHVal=igN(FLARE_H);local maxBankVal=igN(MAX_BANK);local tgtTdPitVal=igN(TGT_TD_PIT_IN);local radarInvVal=igN(RADAR_INV);
    local m2ThrVal=igN(M2_THR);local m2PitVal=igN(M2_PIT);local m2RolVal=igN(M2_ROL);local m2YawVal=igN(M2_YAW);
    local m2WpXVal=igN(M2_DBG_WPX);local m2WpYVal=igN(M2_DBG_WPY);

    local recalcEdgeFlag=false; if recalcBtnVal and not recalcBtnPrev then recalcEdgeFlag=true end; recalcBtnPrev=recalcBtnVal;
    if engageVal and not lastEngage then if cur_state==STATE_IDLE then cur_state=ST_REQ_IAF;recalcEdgeFlag=true;abortRsn="Eng";dbgAbortCodeNum=ABORT_CODE_NONE;else cur_state=STATE_IDLE;abortRsn="Diseng";dbgAbortCodeNum=ABORT_CODE_NONE;end end; lastEngage=engageVal;
    if recalcEdgeFlag and cur_state~=STATE_IDLE and cur_state~=ST_REQ_IAF then cur_state=ST_REQ_IAF;abortRsn="Recalc";dbgAbortCodeNum=ABORT_CODE_NONE;end
    local plausibleMaxRadarHVal=iafAltOffVal+cAltVal+50; if acRadarAVal~=radarInvVal and acRadarAVal>0.1 and acRadarAVal<plausibleMaxRadarHVal then if math.abs(acBaroAVal-(cAltVal+acRadarAVal))<75 then deckDetect=true;deckLossTmr=0 else deckDetect=false end else deckDetect=false end;
    if not deckDetect and(cur_state==ST_ON_GS or cur_state==ST_FLARE or cur_state==ST_TD_AWAIT)then deckLossTmr=deckLossTmr+(1/60) else deckLossTmr=0 end;
    local cmdThrVal=0;local cmdPitVal=0;local cmdRolVal=0;local cmdYawVal=0;local cmdHookFlag=false;local cmdLightFlag=false;
    local distToCVal=dist2d(acXVal,acYVal,cXVal,cYVal);
    local m2AcAltRelVal=acBaroAVal;local m2TgtP1Val=0;local m2TgtP2Val=0;local m2TgtP3Val=0;local m2TgtP4Val=0;local m2IafTrigVal=0.0;

    if cur_state==STATE_IDLE then cmdLightFlag=false;cmdHookFlag=false;tdTimer=0;deckLossTmr=0;awaitIAFTmr=0;dbgAbortCodeNum=ABORT_CODE_NONE;
    elseif cur_state==ST_REQ_IAF then cmdLightFlag=true;m2IafTrigVal=1.0;m2TgtP1Val=iafDistAVal;m2TgtP2Val=iafAltOffVal;iafAlt=cAltVal+iafAltOffVal;cur_state=ST_WAIT_IAF;abortRsn="IAF Req";awaitIAFTmr=0;recalcEdgeFlag=false;
    elseif cur_state==ST_WAIT_IAF then cmdLightFlag=true;awaitIAFTmr=awaitIAFTmr+(1/60);m2TgtP1Val=iafDistAVal;m2TgtP2Val=iafAltOffVal; if m2WpXVal~=0 or m2WpYVal~=0 then iafX=m2WpXVal;iafY=m2WpYVal;cur_state=ST_NAV_IAF;abortRsn="IAF Rcvd";dbgAbortCodeNum=ABORT_CODE_NONE;elseif awaitIAFTmr>2.0 then setAbort("IAF Timeout",ABORT_CODE_IAF_TIMEOUT);else m1StateToSend=ST_REQ_IAF;m2IafTrigVal=0.0;end
    elseif cur_state==ST_NAV_IAF then cmdLightFlag=true;m2TgtP1Val=iafX;m2TgtP2Val=iafY;m2TgtP3Val=iafAlt;m2TgtP4Val=tgtApSpdVal+15;if dist2d(acXVal,acYVal,iafX,iafY)<500 and(iafX~=0 or iafY~=0)then cur_state=ST_ALIGN;abortRsn="IAF Ok"end;
    elseif cur_state==ST_ALIGN then cmdLightFlag=true;cmdHookFlag=true;m2AcAltRelVal=acBaroAVal;m2TgtP1Val=tgtApSpdVal;m2TgtP2Val=cAltVal+iafAltOffVal;m2TgtP3Val=maxBankVal;local angDiff=math.abs(acHdgVal-cHdgVal);if angDiff>180 then angDiff=360-angDiff end;if angDiff<15 and distToCVal<(iafDistAVal*0.8)and distToCVal>2000 then cur_state=ST_GS_ESTAB;abortRsn="Align Ok"else if distToCVal<1500 then setAbort("Close Align",ABORT_CODE_TOO_CLOSE_ALIGN);end end
    elseif cur_state==ST_GS_ESTAB then cmdLightFlag=true;cmdHookFlag=true;if deckDetect then m2AcAltRelVal=acRadarAVal else m2AcAltRelVal=acBaroAVal end;m2TgtP1Val=tgtApSpdVal;m2TgtP2Val=tgtGsDegVal;m2TgtP3Val=maxBankVal;if deckDetect and deckLossTmr==0 then cur_state=ST_ON_GS;abortRsn="GS Ok(R)"else if not deckDetect and distToCVal<1500 and deckLossTmr>3.0 then setAbort("No Radar GS",ABORT_CODE_NO_RADAR_GS);end end
    elseif cur_state==ST_ON_GS then cmdLightFlag=true;cmdHookFlag=true;if not deckDetect then if deckLossTmr>1.0 then setAbort("Lost GS",ABORT_CODE_LOST_RADAR_GS);end else m2AcAltRelVal=acRadarAVal end;m2TgtP1Val=tgtApSpdVal;m2TgtP2Val=tgtGsDegVal;m2TgtP3Val=flareHVal;m2TgtP4Val=maxBankVal;if acRadarAVal<=flareHVal and deckDetect then cur_state=ST_FLARE;abortRsn="Flare H"else if distToCVal<50 and acRadarAVal>flareHVal then setAbort("Miss Flare",ABORT_CODE_MISSED_FLARE);end end
    elseif cur_state==ST_FLARE then cmdLightFlag=true;cmdHookFlag=true;if not deckDetect then if deckLossTmr>0.5 then setAbort("Lost Flare",ABORT_CODE_LOST_RADAR_FLARE);end else m2AcAltRelVal=acRadarAVal end;m2TgtP1Val=tgtApSpdVal-5;m2TgtP2Val=tgtTdPitVal;m2TgtP3Val=maxBankVal;m2TgtP4Val=flareHVal;if acRadarAVal<1.0 and deckDetect then cur_state=ST_TD_AWAIT;abortRsn="Await TD";tdTimer=0;else if acRadarAVal>flareHVal*1.5 then setAbort("Balloon",ABORT_CODE_BALLOONED);end end
    elseif cur_state==ST_TD_AWAIT then cmdLightFlag=true;cmdHookFlag=true;tdTimer=tdTimer+(1/60);if not deckDetect and acRadarAVal>2.0 then if deckLossTmr>0.5 then setAbort("Lost TD/Bounce",ABORT_CODE_LOST_DECK_BOUNCE);end else m2AcAltRelVal=acRadarAVal end;m2TgtP1Val=-1.0;m2TgtP2Val=tgtTdPitVal;if hookedVal then cur_state=ST_LANDED;abortRsn="Hooked!";dbgAbortCodeNum=ABORT_CODE_NONE;else if tdTimer>4.0 then setAbort("Bolter",ABORT_CODE_BOLTER_TIMEOUT);end end
    elseif cur_state==ST_LANDED then cmdLightFlag=false;cmdHookFlag=true;m2TgtP1Val=-1.0;tdTimer=0;deckLossTmr=0;dbgAbortCodeNum=ABORT_CODE_NONE;
    elseif cur_state==ST_ABORT then cmdLightFlag=true;cmdHookFlag=false;m2TgtP1Val=1.0;m2TgtP2Val=acPitVal+10;m2AcAltRelVal=acBaroAVal+200;tdTimer=0;deckLossTmr=0;if acBaroAVal>(cAltVal+iafAltOffVal+100)then end
    end

    if cur_state~=STATE_IDLE and cur_state~=ST_ABORT and cur_state~=ST_LANDED then cmdThrVal=m2ThrVal;cmdPitVal=m2PitVal;cmdRolVal=m2RolVal;cmdYawVal=m2YawVal;
    elseif cur_state==ST_ABORT then cmdThrVal=1.0;cmdPitVal=pidUpd(pidAlt,acPitVal+10,acPitVal,DT);cmdRolVal=0;cmdYawVal=0; -- Make sure pidUpd is defined or this will error
    elseif cur_state==ST_LANDED then cmdThrVal=-1.0;cmdPitVal=0;cmdRolVal=0;cmdYawVal=0;
    end;
    
    isN(OUT_THR,cmdThrVal);isN(OUT_PIT,cmdPitVal);isN(OUT_ROL,cmdRolVal);isN(OUT_YAW,cmdYawVal);
    isN(OUT_WPX,m2WpXVal);isN(OUT_WPY,m2WpYVal);isN(OUT_WPALT,iafAlt);
    isB(OUT_HOOK,cmdHookFlag);isB(OUT_LIGHT,cmdLightFlag);
    local m1StateToSendVal=cur_state;if cur_state==ST_WAIT_IAF then m1StateToSendVal=ST_REQ_IAF end;isN(M1_STATE,m1StateToSendVal);
    isN(M1_AC_X,acXVal);isN(M1_AC_Y,acYVal);isN(M1_AC_ALT_REL,m2AcAltRelVal);isN(M1_AC_HDG,acHdgVal);isN(M1_AC_SPD,acSpdVal);isN(M1_AC_PIT,acPitVal);isN(M1_AC_ROL,acRolVal);
    isN(M1_C_X,cXVal);isN(M1_C_Y,cYVal);isN(M1_C_ALT,cAltVal);isN(M1_C_HDG,cHdgVal);isN(M1_C_SPD,cSpdVal);
    isN(M1_TGT_P1,m2TgtP1Val);isN(M1_TGT_P2,m2TgtP2Val);isN(M1_TGT_P3,m2TgtP3Val);isN(M1_TGT_P4,m2TgtP4Val);
    isN(M1_IAF_TRIG,m2IafTrigVal);isN(M1_DIST_C,distToCVal);
    isN(DBG_M1_STATE,cur_state);
    isN(DBG_ABORT_CODE,dbgAbortCodeNum); 
    isN(DBG_AWAIT_TMR,awaitIAFTmr); 
    isN(DBG_TD_TMR,tdTimer);
end
