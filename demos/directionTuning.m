%% Direction Tuning
% An example application; using poissyFit to determine direction tuning of
% 1000 neurons.
% The data set has :
% F - Neuropil corrected Fluorescence [nrTimePoints nrTrials nrROI]
% stdF - Standard deviation of F
% spk - Deconvolved spiking activity
% binWidth
% direction - Direction of motion in each trial [1 nrTrials]
%
% These data were recorded with Scanbox/Neurolabware and preprocessed using
% default parameters of Suite2p.
%
%%
%{
% Code to generate the exampleData file - needs access to the klabData and
DataJoint server

roi = sbx.Roi & 'session_date = ''2023-03-23''' & 'pcell>0.95';
expt = ns.Experiment & 'session_date = ''2023-03-23''' & 'paradigm like ''Ori%''' & 'starttime=''12:56:11''';
stepSize = 1/15.5;
trialsToKeep =2:120; % The first trial has some nan in it at the start.
nrRois = 1000;
fetchOptions = ['ORDER BY pCell Desc LIMIT ' num2str(nrRois)] ; % Take the top nrRois neurons
[f] = get(roi ,expt, trial= trialsToKeep, modality = 'fluorescence',start=0.5,stop=1.5,step=stepSize,interpolation ='nearest',fetchOptions = fetchOptions);
[np] = get(roi ,expt,trial= trialsToKeep,  modality = 'neuropil',start=0.5,stop=1.5,step=stepSize,interpolation ='nearest',fetchOptions = fetchOptions);
stdF = [fetch(roi,'stdfluorescence',fetchOptions).stdfluorescence];
[spk] = get(roi,expt,trial= trialsToKeep, modality = 'spikes',start=0.5,stop=1.5,step=stepSize,interpolation ='nearest',fetchOptions = fetchOptions);
direction = get(expt ,'gbr','prm','orientation','atTrialTime',0);
direction =direction(trialsToKeep);

save exampleData f np stdF spk direction nrRois stepSize

% Note that the outcome of this comparison is that (for these data, and
these parameter settings),using the deconvolved spikes leads to better
performance (better split-halves correlation) than using the (neuropil
corrected) fluorescence.

%}

nrBoot = 10;        % Bootstrap iterations for splitHalves
POISSYFIT =true;    % Run poissyFit on all ROI
nrBayesRoi = 100;   % Because bayesFit takes so long, run only a subset of ROI
GRAPH = false;      % Show graphs

% Load the data and rearrange.
load ../data/exampleData
thisTimes =seconds(0.5:stepSize:1.5);
f = retime(f,thisTimes,'linear');
[nrTimePoints, nrTrials] = size(f);
f = permute(double(reshape(f.Variables,[nrTimePoints nrRois nrTrials])),[1 3 2]);
np = retime(np,thisTimes,'linear');
np = permute(double(reshape(np.Variables,[nrTimePoints nrRois nrTrials])),[1 3 2]);
F  = f-0.7*np;
spk = retime(spk,thisTimes,'linear');
spk= permute(double(reshape(spk.Variables,[nrTimePoints nrRois nrTrials])),[1 3 2]);


%% Initialize
nrRois  = size(F,3);
r       = nan(nrRois,1);
rSpk    = nan(nrRois,1);
rCross  = nan(nrRois,1);
gof  = nan(nrRois,1);
parms  = nan(nrRois,5);
parmsError=nan(nrRois,5);

%% FIT
% For each ROI, fit a logTwoVonMises, bootstrap the parameter estimates and
% determined the splitHalves correlation.

nrWorkers = gcp('nocreate').NumWorkers ; % Parfor for bootstrapping
spikeCountDist = "POISSON";    
if POISSYFIT
    for roi =1:nrRois
        fprintf('ROI #%d (%s)\n',roi,datetime('now'))
        o = poissyFit(direction,F(:,:,roi),stepSize,@poissyFit.logTwoVonMises,fPerSpike=500,scaleToMax=true);
        o.spikeCountDistribution = spikeCountDist;
        switch spikeCountDist
            case "POISSON"
                o.hasDerivatives = 1;
                o.options =    optimoptions(@fminunc,'Algorithm','trust-region', ...
                    'SpecifyObjectiveGradient',true, ...
                    'display','none', ...
                    'CheckGradients',false, ... % Set to true to check supplied gradients against finite differences
                    'diagnostics','off');
            case "EXPONENTIAL"
                o.hasDerivatives = 0;
                o.options =    optimoptions(@fminunc,'Algorithm','quasi-newton', ...
                    'SpecifyObjectiveGradient',false, ...
                    'display','none', ...
                    'diagnostics','off');
        end
        o.measurementNoise =stdF(roi);
        o.nrWorkers = nrWorkers;
        try
            solve(o,nrBoot);
            parms(roi,:) =o.parms;
            parmsError(roi,:)= o.parmsError;
            gof(roi) = o.gof;
            [r(roi),~,rSpk(roi),~,rCross(roi)] = splitHalves(o,nrBoot,[],spk(:,:,roi));
        catch me
            fprintf('Failed on roi #%d (%s)',roi,me.message)
        end
    end
end

%% Optional - Compare with bayesFit
% This only runs if nrBayesRoi >0
nrParms = 4; % Circular gaussian 360 has 4 parms
parmsBf  = nan(nrParms,nrRois);
errorBf=nan(nrParms,nrRois);
rBf = nan(nrRois,1);
bf = nan(nrRois,1);
if nrBayesRoi >0
    x= repmat(direction,[nrTimePoints 1]);
    x=x(:);
    parfor roi =1:nrBayesRoi
        fprintf('BayesFit ROI #%d (%s)\n',roi,datetime('now'))
        y=spk(:,:,roi);
        y = y(:);
        [rBf(roi),bf(roi),parmsBf(:,roi),errorBf(:,roi)]= splitHalves(x,y,"fun","circular_gaussian_360","nrBoot",nrBoot,'nrWorkers',1);
    end
end
%% Save
save ("../data/directionTuning" + spikeCountDist + ".mat", 'r','rSpk', 'rCross','parms','parmsError','gof','rBf','bf','errorBf','parmsBf')

if GRAPH
    %% Show Results
    figure(1);
    clf
    % Scatter of split halves correlation for df/F vs spk
    subplot(2,2,1)
    scatter(r,rSpk);
    axis equal
    ylim([-1 1])
    xlim([-1 1])
    hold on
    plot(xlim,xlim,'k')
    xlabel 'r_F'
    ylabel 'r_{spk}'
    title (sprintf('Split halves correlation: Delta = %.2f (p=%.3g)',mean(rSpk-r),ranksum(r,rSpk)))

    subplot(2,2,2)
    % Scatter of standard devaition of PO across bootstraps against the split halves correlation for df/F and spk
    scatter(r,parmsError(:,2),'.')
    xlabel 'r'
    ylabel 'bootstrap stdev PO (deg)'
    hold on
    plot(xlim,[20 20])
    scatter(rSpk,parmsError(:,2),'.')
    plot(xlim,[20 20])
    legend('dF/F','spk')


    % Bayesfit results.
      % Scatter of split halves correlation for BF vs spk
    subplot(2,2,3)
    notNan = ~isnan(rBf);
    scatter(rSpk(notNan),rBf(notNan))
    hold on
    axis equal
    ylim([-1 1])
    xlim([-1 1])
    plot(xlim,xlim,'k')
    ylabel 'r_{bf}'
    xlabel 'r_{spk}'
    title (sprintf('Split halves correlation: Delta = %.2f (p=%.3g)',mean(rBf(notNan)-rSpk(notNan)),ranksum(rBf(notNan),rSpk(notNan))))

    % Scatter of standard devaition of PO across bootstraps against the split
    % halves correlation for  BF
    subplot(2,2,4)
    scatter(rBf(notNan),errorBf(3,notNan),'.')
    xlabel 'r_{bf}'
    ylabel 'stdev (deg)'
    hold on
    plot(xlim,[20 20])

end