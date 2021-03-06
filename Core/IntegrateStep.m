function [Conc,Time,StepIndex,RepIndex,k_solar,SZA_solar] = ...
    IntegrateStep(i,j,nIc,conc_init,conc_last,conc_bkgd,ModelOptions,Chem,k,Sbroad,Sslice,Mbroad,Mslice)
% function [Conc,Time,StepIndex,RepIndex,k_solar,SZA_solar] = ...
%     IntegrateStep(i,j,nIc,conc_init,conc_last,conc_bkgd,ModelOptions,Chem,k,Sbroad,Sslice,Mbroad,Mslice)
% Performs integration of chemical ODEs for a single set of inputs/constraints.
%
% INPUTS:
%   i:              scalar index for current step
%   j:              scalar index for current repetition
%   nIC:            total number of steps
%   conc_init:      1-D vector if initial concentrations
%   conc_last:      1-D vector of output from previous step. Only needed if steps are linked.
%   conc_bkgd:      1-D vector of background concentrations
%   ModelOptions:   structure of model options
%   Chem:           structure of chemistry variables (ChemFiles,f,iG,iRO2,iNOx,iHold)
%   Sbroad:         SolarParam broadcast variable structure, generated from struct2parvar
%   Sslice:         SolarParam sliced variable 1-D array
%   Mbroad:         Met broadcast variable structure
%   Mslice:         Met sliced variable 1-D array
%
% OUTPUTS (size depends on ModelOptions)
%   Conc:       matrix of calculated concentrations
%   Time:       integration time, s
%   StepIndex:  linear index for step
%   RepIndex:   linear index for rep
%   k_solar:    rate constants used in solar cycle calculation
%   SZA_solar:  SZA cycle used in solar cycle calculation
%
% 20180227 GMW

if ModelOptions.Verbose>=1
    fprintf('Step %u of %u\n',i,nIc)
    tic
end

%% MASSAGE INPUTS

Met         = parvar2struct(Mbroad,Mslice);
SolarParam  = parvar2struct(Sbroad,Sslice);

if ~isnan(SolarParam.nDays), SolarFlag = 1;
else,                        SolarFlag = 0;
end

nSp = length(conc_init);

%% GET SOLAR-EVOLVING CHEMISTRY
if SolarFlag
    
    %%%%% CALCULATE SZA CYCLE %%%%%
    cycleTime = ModelOptions.IntTime:ModelOptions.IntTime:86400; %cycle for one day
    extendTime = repmat(cycleTime,1,SolarParam.nDays);
    
    sTime.year  = SolarParam.startTime(1); 
    sTime.month = SolarParam.startTime(2);
    sTime.day   = SolarParam.startTime(3); 
    sTime.hour  = SolarParam.startTime(4);
    sTime.min   = SolarParam.startTime(5); 
    sTime.sec   = SolarParam.startTime(6) + extendTime;
    sTime.UTC   = 0;
    
    location.longitude  = SolarParam.lon;
    location.latitude   = SolarParam.lat;
    location.altitude   = SolarParam.alt;
    
    sun = sun_position(sTime,location); %zenith and azimuth angles of sun
    sun.zenith(sun.zenith>90) = 90;
    nSolar = length(extendTime);
    
    %%%%% EXTEND MET %%%%%
    Mnames = fieldnames(Met);
    for m=1:length(Mnames)
        solarMet.(Mnames{m}) = repmat(Met.(Mnames{m}),nSolar,1);
    end
    solarMet.SZA = sun.zenith;
    
    %calculate rate constants
    [~,~,k] = InitializeChemistry(solarMet,Chem.ChemFiles,ModelOptions,0);
    
else
    nSolar = 1;
end

%% DO INTEGRATION

Conc = nan(nSolar,nSp); %placeholder only; might get overwritten if output is single-point
Time = nan(nSolar,1);

for h = 1:nSolar
    
    if ModelOptions.Verbose>=2 && SolarFlag
        fprintf('Solar Cycle %u of %u\n',h,nSolar);
    end
    
    %%%%% INITIALIZE CONCENTRATIONS %%%%%
    if ~isempty(conc_last)
        conc_init_step = conc_last; %carry over end concs from previous step
        conc_init_step(Chem.iHold) = conc_init(Chem.iHold); % override for held species
        if ModelOptions.FixNOx
            modelNOx = conc_last(Chem.iNOx);
            initNOx = conc_init(Chem.iNOx);
            conc_init_step(Chem.iNOx) = modelNOx.*sum(initNOx)./sum(modelNOx);
            % NOxinfo = [iNOx;initNOx]; %for adjustment in dydt_eval
        end
    else
        conc_init_step = conc_init;
    end
    
    %%%%% CALL ODE SOLVER %%%%%
    param = {...    %parameters for dydt_eval
        k(h,:),...
        Chem.f,...
        Chem.iG,...
        Chem.iRO2,...
        Chem.iHold,...
        Met.kdil,...
        Met.tgauss,...
        conc_bkgd,...
        ModelOptions.IntTime,...
        ModelOptions.Verbose,...
        };
    
    options = odeset('Jacobian',@(t,conc_out) Jac_eval(t,conc_out,param)); %Jacobian speeds integration
    
    [time_out,conc_out] = ode15s(@(t,conc_out) dydt_eval(t,conc_out,param),...
        [0 ModelOptions.IntTime],conc_init_step',options);
    
    %%%%% TIME OFFSETS %%%%%
    if SolarFlag
        time_out = time_out + (h-1).*ModelOptions.IntTime;
    elseif ModelOptions.LinkSteps
        time_out = time_out + (i-1).*ModelOptions.IntTime + (j-1).*nIc.*ModelOptions.IntTime;
    end
    
    %%%%% OUTPUT %%%%%
    if ModelOptions.EndPointsOnly
        Conc = conc_out(end,:);
        Time = time_out(end);
    elseif SolarFlag
        % in this case, output end of each mini-step
        Conc(h,:) = conc_out(end,:);
        Time(h) = time_out(end);
    else
        Conc = conc_out;
        Time = time_out;
    end
    
    % initialize next step if needed
    conc_last = conc_out(end,:);
    
end %end Solar for-loop

%%%%% OTHER OUTPUTS %%%%%
StepIndex = i.*ones(size(Time));
RepIndex  = j.*ones(size(Time));
        
if SolarFlag
    SZA_solar = solarMet.SZA;
    if ModelOptions.EndPointsOnly
        k_solar = k(end,:);
    else
        k_solar = k;
    end
else
    SZA_solar = [];
    k_solar = [];
end

if ModelOptions.Verbose>=1
    dt = datestr(toc/86400,'HH:MM:SS');
    fprintf('  Step %u time: %s\n',i,dt)
end


