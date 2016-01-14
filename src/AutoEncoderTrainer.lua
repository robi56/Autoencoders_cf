dofile("Tikhonov.lua")
AutoEncoderTrainer = {}


function AutoEncoderTrainer:new(network, conf, train, test, info, maxIndex)

   local newObj =
      {
         network  = network,
         loss     = conf.criterion,
         train    = train,
         test     = test,
         info     = info,
         isSparse = network.isSparse or false,
         maxIndex = maxIndex,
         rmse     = {},
         mae      = {},
      }

--   if network.isSparse then
--      newObj.tikhonov = nnsparse.Tikhonov(conf.weightDecay, newObj.network)
--      conf.weightDecay = 0
--      conf.weightDecays = newObj.tikhonov.lambdas
--   end


   self.__index = self

   return setmetatable(newObj, self)

end



function AutoEncoderTrainer:Train(sgdOpt, epoch)

   -- pick alias
   local network = self.network
   local lossFct = self.loss
   local inputs  = self.train

   -- Retrieve parameters and gradients
   local w, dw = network:getParameters()

   -- remove Torch size average, aka 1/n, for loss)
   lossFct.sizeAverage = false

   -- bufferize minibatch
   local input
   if network.isSparse then input = {}
   else                     input = inputs.new(sgdOpt.miniBatchSize, inputs[1]:size(1))
   end
   
   -- prepare meta-data
   local denseMetadata  = inputs[1].new(sgdOpt.miniBatchSize, self.info.metaDim)
   local sparseMetadata = {}
   
   local appenderIn = sgdOpt.appenderIn or nnsparse.AppenderDummy:new()

   -- shuffle index for data
   local noSample = GetSize(inputs)
   local shuffle  = torch.randperm(noSample)


   -- Start training
   network:training()

   local cursor   = 1
   while cursor < noSample-1 do

      -- prepare minibatch
      local noPicked = 1
      while noPicked <= sgdOpt.miniBatchSize and cursor < noSample-1 do

         local shuffledIndex = shuffle[cursor]
         if inputs[shuffledIndex] then -- warning tables are not always continuous
            input[noPicked] = inputs[shuffledIndex]
            
            denseMetadata[noPicked]  = self.info[shuffledIndex].full
            sparseMetadata[noPicked] = self.info[shuffledIndex].fullSparse

            noPicked = noPicked + 1
         end

         cursor = cursor + 1
      end


      -- Define the closure to evalute w and dw
      local function feval(x)

         -- Reset gradients and losses
         network:zeroGradParameters()

         --Prepare metadata
         appenderIn:prepareInput(denseMetadata, sparseMetadata)

         -- AutoEncoder targets
         local target = input
      
         -- Compute noisy input for Denoising AutoEnc 
         local noisyInput = lossFct:prepareInput(input) 
         

         --- FORWARD
         local output = network:forward(noisyInput)
         local loss   = lossFct:forward(output, target)
         
         --- BACKWARD
         local dloss = lossFct:backward(output, target)
         local _     = network:backward(noisyInput, dloss)

         -- Return loss and gradients
         return loss/sgdOpt.miniBatchSize, dw:div(sgdOpt.miniBatchSize)
      end


      -- Optimize current iteration
      sgdOpt.evalCounter = epoch

      -- compute new regularization according input/output 
      if self.tikhonov then
         self.tikhonov:computeLambda(input)
      end

      optim.sgd (feval, w, sgdOpt )

   end


end



function  AutoEncoderTrainer:Test(sgdOpt)

   local network = self.network

   local train   = self.train
   local test    = self.test

   local loss, rmse, mae = NaN,NaN,NaN


   -- start evaluating
   network:evaluate()

   local appenderIn = sgdOpt.appenderIn or nnsparse.AppenderDummy:new()

   if self.isSparse then

      -- Configure prediction error
      local rmseFct = nnsparse.SparseCriterion(nn.MSECriterion())
      local maeFct  = nnsparse.SparseCriterion(nn.AbsCriterion())

      rmseFct.sizeAverage = false
      maeFct.sizeAverage  = false

      rmse, mae = 0, 0

      --Prepare minibatch
      local inputs  = {}
      local targets = {}

      -- prepare meta-data
      local denseMetadata  = train[1].new(sgdOpt.miniBatchSize, self.info.metaDim)
      local sparseMetadata = {}

      local i = 1
      local noSample = 0

      for k, input in pairs(train) do

         -- Focus on the prediction aspect
         local target = test[k]

         -- Ignore data with no testing examples
         if target ~= nil then

            inputs[i]  = input

            targets[i] = targets[i] or target.new()
            targets[i]:resizeAs(target):copy(target)

            -- center the target values
            targets[i][{{}, 2}]:add(-self.info[k].mean)

            denseMetadata[i]  = self.info[k].full
            sparseMetadata[i] = self.info[k].fullSparse


            noSample = noSample + target:size(1)
            i = i + 1

            --compute loss when minibatch is ready
            if #inputs == sgdOpt.miniBatchSize then

               --Prepare metadata
               appenderIn:prepareInput(denseMetadata, sparseMetadata)

               local output = network:forward(inputs)

               rmse = rmse + rmseFct:forward(output, targets)
               --mae  = mae  + maeFct:forward(output, targets)

               --reset minibatch
               inputs = {}
               i = 1

            end
         end
      end

      -- remaining data for minibatch
      if #inputs > 0 then
         local _targets = {unpack(targets, 1, #inputs)} --retrieve a subset of targets
         
         local _sparseMetadata = {unpack(sparseMetadata, 1, #inputs)}
         local _denseMetadata =  denseMetadata[{{1, #inputs},{}}] 
         
         appenderIn:prepareInput(_denseMetadata, _sparseMetadata)
        
         local output = network:forward(inputs)

         rmse = rmse + rmseFct:forward(output, _targets)
         --mae  = mae  + maeFct:forward(output , _targets)
     end

      rmse = rmse/noSample
      mae  = mae/noSample

      local w, dw = network:getParameters()


      --print("FULL : " .. math.sqrt(rmseFct:forward(network:forward(self.train), self.test))*2)

   else
      -- compute reconstruction loss
      local lossFct = nn.MSECriterion()

      local outputLoss = network:forward(test)
      loss = lossFct:forward(outputLoss, test)
   end

   return math.sqrt(loss), math.sqrt(rmse), mae

end




function AutoEncoderTrainer:Execute(sgdOpt)


   local noEpoch = sgdOpt.noEpoch

   for t = 1, noEpoch do

      if SHOW_PROGRESS == true then xlua.progress(t, noEpoch) end

      --train one epoch
      self:Train(sgdOpt, t)

      local newReconstructionRMSE, newPredictionRMSE, newMAE = self:Test(sgdOpt)

      --resclase RMSE/MAE
      newPredictionRMSE     = newPredictionRMSE     * 2
      newMAE                = newMAE                * 2

      self.rmse[#self.rmse+1] =  newPredictionRMSE
      self.mae [#self.mae +1] =  newMAE


      if newPredictionRMSE ~= NaN and newMAE ~= NaN then
         print(t .. "/" .. noEpoch .. "\t RMSE : "  .. newPredictionRMSE .. "\t MAE : "  .. newMAE )
      end

      if newReconstructionRMSE ~= NaN  then
         print(t .. "/" .. noEpoch .. "\t RMSE : "  .. newReconstructionRMSE )
      end

   end

   return self.rmse, self.mae

end






