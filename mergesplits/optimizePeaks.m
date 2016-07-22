% addpath('C:\CODE\GitHub\KiloSort\preDetect')

nProj = size(uproj,2);
nSpikesPerBatch = 4000;
inds = 1:nSpikesPerBatch * floor(size(uproj,1)/nSpikesPerBatch);
inds = reshape(inds, nSpikesPerBatch, []);
% Nbatch = size(inds,2);
iperm = randperm(size(inds,2));
miniorder = repmat(iperm, 1, ops.nfullpasses);
%     miniorder = repmat([1:Nbatch Nbatch:-1:1], 1, ops.nfullpasses/2);

if ~exist('spikes_merged')
    uBase = zeros(1e4, nProj);
    nS = zeros(1e4, 1);
    ncurr = 1;
    
    for ibatch = 1:size(inds,2)
        % merge in with existing templates
        uS = uproj(inds(:,ibatch), :);
        [nSnew, iNonMatch] = merge_spikes0(uBase(1:ncurr,:), nS(1:ncurr), uS, ops.crit);
        nS(1:ncurr) = nSnew;
        %
        % reduce non-matches
        [uNew, nSadd] = reduce_clusters0(uS(iNonMatch,:), ops.crit);
        
        % add new spikes to list
        uBase(ncurr + [1:size(uNew,1)], :) = uNew;
        nS(ncurr + [1:size(uNew,1)]) = nSadd;
        
        ncurr = ncurr + size(uNew,1);
        
        if ncurr>1e4
            break;
        end
    end
    %
    nS = nS(1:ncurr);
    uBase = uBase(1:ncurr, :);
    spikes_merged = 1;
end
[nS_sorted, itsort] = sort(nS, 'descend');

%% initialize U
Nfilt = ops.Nfilt;
% check that Nfilt valid filters would exist
minNfilt = min(size(find(nS_sorted(1:Nfilt)),1),Nfilt);
if minNfilt < Nfilt
    sprintf('Warning: optimizePeaks.m resetting Nfilt from %d to %d.\n',Nfilt,minNfilt)
    Nfilt = minNfilt;
    ops.Nfilt = minNfilt; 
end

lam = ops.lam(1) * ones(Nfilt, 1, 'single');

U = gpuArray(uBase(itsort(1:Nfilt), :))';
mu = sum(U.^2,1)'.^.5;
U = normc(U);
%

for i = 1:10
    
    idT = zeros(size(inds));
    dWU = zeros(Nfilt, nProj, 'single');
    nToT = gpuArray.zeros(Nfilt, 1, 'single');
    Cost = gpuArray(single(0));
    
    for ibatch = 1:size(inds,2)
        % find clusters
        clips = reshape(gpuArray(uproj(inds(:,ibatch), :)), nSpikesPerBatch, nProj);
        
        ci = clips * U;
        
        ci = bsxfun(@plus, ci, (mu .* lam)');
        cf = bsxfun(@rdivide, ci.^2, 1 + lam');
        cf = bsxfun(@minus, cf, (mu.^2.*lam)');
        
        [max_cf, id] = max(cf, [], 2);
        
        id = gather(id);
        %        x = ci([1:nSpikesPerBatch] + nSpikesPerBatch * (id-1)')' - mu(id) .* lam(id);
        idT(:,ibatch) = id;
        
        L = gpuArray.zeros(Nfilt, nSpikesPerBatch, 'single');
        L(id' + [0:Nfilt:(Nfilt*nSpikesPerBatch-1)]) = 1;
        dWU = dWU + L * clips;
        
        nToT = nToT + sum(L, 2);
        Cost = Cost + mean(max_cf);
    end
    dWU  = bsxfun(@rdivide, dWU, nToT);
    
    U = dWU';
    mu = sum(U.^2,1)'.^.5;
    U = normc(U);
    Cost = Cost/size(inds,2);
    
%     disp(Cost)
    
%     plot(sort(log(1+nToT)))
%     drawnow
end
%%
Nchan = ops.Nchan;
Nfilt = ops.Nfilt;
wPCA = ops.wPCA(:,1:3);
Urec = reshape(U, Nchan, size(wPCA,2), Nfilt);

nt0 = 61;
Urec= permute(Urec, [2 1 3]);
Wrec = reshape(wPCA * Urec(:,:), nt0, Nchan, Nfilt);

Wrec = gather(Wrec);
Nrank = 3;
W = zeros(nt0, Nfilt, Nrank, 'single');
U = zeros(Nchan, Nfilt, Nrank, 'single');
for j = 1:Nfilt
    [w sv u] = svd(Wrec(:,:,j));
    w = w * sv;
    
    Sv = diag(sv);
    W(:,j,:) = w(:, 1:Nrank)/sum(Sv(1:ops.Nrank).^2).^.5;
    U(:,j,:) = u(:, 1:Nrank);
end

Uinit = U;
Winit = W;
mu = gather(single(mu));
muinit = mu;

WUinit = zeros(nt0, Nchan, Nfilt);
for j = 1:Nfilt
    WUinit(:,:,j) = muinit(j)  * Wrec(:,:,j);
end
WUinit = single(WUinit);
%%


