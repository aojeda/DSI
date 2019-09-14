function EEG = pop_rsbl(EEG, saveFull, account4artifacts, src2roiReductionType, solverType, updateFreq)
persistent solver

if nargin < 1, error('Not enough input arguments.');end
if nargin == 1
    answer = inputdlg({'Save full PCD (true/false)','Account for artifacts (true/false)', 'Source ROI type (power, mpower, ksdensity, hist, sum, or mean)', 'Solver type (bsbl, loreta)','Update model every k samples'},'pop_pebp', 1, {'true', 'true','power','bsbl','1'});
    if isempty(answer)
        return;
    else
        saveFull = str2num(lower(answer{1})); %#ok
        account4artifacts = str2num(lower(answer{2})); %#ok
        src2roiReductionType = lower(answer{3});
        solverType = lower(answer{4});
        updateFreq = str2double(lower(answer{5}));
    end
end
if ~islogical(saveFull)
    disp('Invalid input for saveFull parameter, we will use the default value.')
    saveFull= true;
end
account4artifacts = logical(account4artifacts);
if isempty(account4artifacts)
    disp('Invalid input for account4artifacts parameter, we will use the default value.')
    account4artifacts= true;
end
if ~any(ismember({'ksdensity','hist','mean','sum','power','mpower'},src2roiReductionType))
    src2roiReductionType = 'power';
end
if ~any(ismember({'bsbl','loreta'},solverType))
    solverType = 'bsbl';
end
updateFreq = max([1 updateFreq]);
updateFreq = min([updateFreq round(0.08*EEG.srate)]);

% Load the head model
try
    hm = headModel.loadFromFile(EEG.etc.src.hmfile);
catch
    warning('EEG.etc.src.hmfile seems to be corrupted or missing, to set it right next we will run >> EEG = pop_forwardModel(EEG)');
    EEG = pop_forwardModel(EEG, headModel.getDefaultTemplateFilename(), [0.33 0.022 0.33], true);
    try
        hm = headModel.loadFromFile(EEG.etc.src.hmfile);
    catch
        errordlg('For the second time EEG.etc.src.hmfile seems to be corrupted or missing, try the command >> EEG = pop_forwardModel(EEG);');
        return;
    end
end

% Select channels
labels_eeg = {EEG.chanlocs.labels};
[~,loc] = intersect(lower(labels_eeg), lower(hm.labels),'stable');
EEG = pop_select(EEG,'channel',loc);

if size(hm.K,2) == 3*size(hm.cortex.vertices,1)
    hm.K = -hm.K;   % Fix polarity bug (OpenMEEG seems to invert the polarity of dipoles when they are not normal to the cortex)
end

% Initialize the inverse solver
if account4artifacts && exist('Artifact_dictionary.mat','file')
    [H, Delta, blocks, indG, indV] = buildAugmentedLeadField(hm);
else
    norm_K = norm(hm.K);
    H = hm.K/norm_K;
    Delta = hm.L/norm_K;
    H = bsxfun(@rdivide,H,sqrt(sum(H.^2)));
    if size(H,2) == 3*size(hm.cortex.vertices,1)
        Delta = kron(eye(3),Delta);
        blocks = hm.indices4Structure(hm.atlas.label);
        blocks = logical(kron(eye(3),blocks));
    end
    indG = (1:size(H,2))';
    indV = [];
end
Nx = size(H,2);
if isempty(solver)
    solver = RSBL(H, Delta, blocks);
else
    try
        if sum((solver.H(:) - H(:)).^2) + sum((solver.Delta(:) - Delta(:)).^2) + sum((solver.Blocks(:) - blocks(:)).^2) ~=0
            solver = RSBL(H, Delta, blocks); 
        end
    catch ME
        if ~strcmp(ME.identifier,'MATLAB:dimagree')
            disp(ME);
        end
        solver = RSBL(H, Delta, blocks);
    end
end
solver.defaultOptions.verbose = false;
if strcmp(solverType,'loreta')
    solver.defaultOptions.doPruning = false;
end
EEG.data = double(EEG.data);
Nroi = length(hm.atlas.label);

% Allocate memory
if saveFull
    X = allocateMemory([Nx, EEG.pnts, EEG.trials]);
end
X_roi = zeros(Nroi, EEG.pnts, EEG.trials);

prc_5 = round(linspace(1,EEG.pnts,30));
iterations = 1:5:EEG.pnts;
prc_10 = iterations(round(linspace(1,length(iterations),11)));
prc_10(1) = [];

logE = zeros([EEG.pnts,EEG.trials]);
lambda = zeros([EEG.pnts,EEG.trials]);
gamma_F = zeros([EEG.pnts,EEG.trials]);
gamma = zeros([solver.Ng,EEG.pnts,EEG.trials]);
E = EEG.data*0;

I = speye(Nx);
B = -sign(Delta);
B = B-diag(diag(B));
B = -bsxfun(@rdivide, B,(sum(B,2)+eps));
B = B+speye(Nx);
A = (0.7*I-0.3*B);

% Determine noise level
n = 2*round(EEG.srate/2);
Y = fft(EEG.data,n, 2);
Y = Y(:,2:n/2+1,:);
D = 1./(1:n/2);
lambda0 = D'*(D'\mean(abs(Y),3)');
lambda0 = mean(mean(lambda0(end-round(n/2/3):end,:)));
fprintf('Approximated noise level: %f\n', lambda0);

Yhat = EEG.data;

% Perform source estimation
fprintf('RSBL filtering...\n');
for trial=1:EEG.trials
    tic;
%     textprogressbar(sprintf('Processing trial %i of %i...',trial, EEG.trials));
    fprintf('Processing trial %i of %i...',trial, EEG.trials);
    
    [X_k, lambda(1,trial),gamma_F(1,trial),gamma(:,1,trial), logE(1,trial)] = solver.update(EEG.data(:,1,trial), lambda0);
    if saveFull
        X(:,1,trial) = X_k;
    end
    X_roi(:,1,trial) = computeSourceROI(X_k(indG), hm, src2roiReductionType);
    Yhat(:,1,trial) = H(:, indG)*X_k(indG);
    K = solver.getK(lambda(1,trial), gamma(:,1,trial));
    for k=2:EEG.pnts
        
        % Prediction
        Xpred = A*X_k; %X(:,k-1,trial);
        e = EEG.data(:,k,trial) - solver.predict(Xpred);
        E(:,k,trial) = e;
              
        % Source estimation
        if ~mod(k,updateFreq)
            [~, lambda(k,trial),gamma_F(k,trial),gamma(:,k,trial), logE(k,trial)] = solver.update(e, lambda(k-1,trial), gamma(:,k-1,trial));
            K = solver.getK(lambda(k,trial), gamma(:,k,trial));
        else
            lambda(k,trial) = lambda(k-1,trial);
            gamma_F(k,trial) = gamma_F(k-1,trial);
            gamma(:,k,trial) = gamma(:,k-1,trial);
            logE(k,trial) = logE(k-1,trial);
        end
        X_k = Xpred + K*e;
        if saveFull
            X(:,k,trial) = X_k;
        end
        
        % Compute ROI signal
        X_roi(:,k,trial) = computeSourceROI(X_k(indG), hm, src2roiReductionType);
        
        % Clean EEG
        Yhat(:,k,trial) = H(:, indG)*X_k(indG);
        
        % Progress indicatior
        if any(prc_5==k)
            fprintf('.');
        end
        prc = find(prc_10==k);
        if ~isempty(prc), fprintf('%i%%',prc*10);end
    end
    fprintf('\n');
    toc
end
EEG.data = Yhat;
EEG.etc.src.act = X_roi;
EEG.etc.src.roi = hm.atlas.label;
EEG.etc.src.lambda = lambda;
EEG.etc.src.gamma = gamma;
EEG.etc.src.H = H;
EEG.etc.src.indG = indG;
EEG.etc.src.indV = indV;
EEG.etc.src.logE = logE;
fprintf('done\n');

if saveFull
    try
        EEG.etc.src.actFull = X;
    catch
        EEG.etc.src.actFull = invSol.LargeTensor([Nx, EEG.pnts, EEG.trials], tempname);
        EEG.etc.src.actFull(:) = X(:);
    end
else
    EEG.etc.src.actFull = [];
end
EEG.history = char(EEG.history,['EEG = pop_rsbl(EEG, ' num2str(saveFull) ', ' num2str(account4artifacts)  ', ''' num2str(src2roiReductionType) ''', ''' solverType ''', ' num2str(updateFreq) ');']);
disp('The source estimates were saved in EEG.etc.src');
end


%%
function x_roi = computeSourceROI(X, hm, src2roiReductionType)
% Construct the sum and average ROI operator
T = hm.indices4Structure(hm.atlas.label);
T = double(T)';
P = sparse(bsxfun(@rdivide,T, sum(T,2)));

% Find if we need to integrate over Jx, Jy, Jz components
isVect = length(X) == 3*size(hm.cortex.vertices,1);
if isVect
    P = [P P P]/3;
    T = [T T T];
end
Nroi = size(P,1);
x_roi = zeros(Nroi,1);
if strcmp(src2roiReductionType,'mean')
    if isVect
        warning('In a solution with (x,y,z) components, the ROI ''mean'' may not make a lot of sense, consider using the ''mpower'' (mean power) option, which is equivalent to taking the mean of dipole magnitudes.');
    end
    x_roi = P*X;
elseif strcmp(src2roiReductionType,'sum')
    if isVect
        warning('In a solution with (x,y,z) components, the ROI ''sum'' may not make a lot of sense, consider using the ''power'' (total power), which takes the sum of dipole magnitudes.');
    end
    x_roi = T*X;
elseif strcmp(src2roiReductionType,'power')
    x_roi = sqrt(T*(X.^2));
elseif strcmp(src2roiReductionType,'mpower')
     x_roi = sqrt(P*(X.^2));
end
end

%%
function X = allocateMemory(dim)
try
    X = zeros(dim);
catch ME
    disp(ME.message)
    disp('Using a LargeTensor object...')
    X = LargeTensor(dim);
end
end
