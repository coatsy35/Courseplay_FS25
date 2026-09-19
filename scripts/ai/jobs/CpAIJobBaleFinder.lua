--- Bale finder job.
---@class CpAIJobBaleFinder : CpAIJobFieldWork
---@field selectedFieldPlot FieldPlot
CpAIJobBaleFinder = CpObject(CpAIJob)
CpAIJobBaleFinder.name = "BALE_FINDER_CP"
CpAIJobBaleFinder.jobName = "CP_job_baleCollect"
--- Keep the nearby search within the bale finder's permitted field-start distance.
CpAIJobBaleFinder.maxNearbyFieldDistance = 20
function CpAIJobBaleFinder:init(isServer)
	CpAIJob.init(self, isServer)
	self.selectedFieldPlot = FieldPlot(true)
    self.selectedFieldPlot:setVisible(false)
	self.selectedFieldPlot:setBrightColor()
end

function CpAIJobBaleFinder:setupTasks(isServer)
	CpAIJob.setupTasks(self, isServer)
	self.baleFinderTask = CpAITaskBaleFinder(isServer, self)
	self:addTask(self.baleFinderTask)
end

function CpAIJobBaleFinder:setupJobParameters()
	CpAIJob.setupJobParameters(self)
    self:setupCpJobParameters(CpBaleFinderJobParameters(self))
end

function CpAIJobBaleFinder:getIsAvailableForVehicle(vehicle, cpJobsAllowed)
	return CpAIJob.getIsAvailableForVehicle(self, vehicle, cpJobsAllowed) and vehicle.getCanStartCpBaleFinder and vehicle:getCanStartCpBaleFinder() -- TODO_25
end

function CpAIJobBaleFinder:getCanStartJob()
	return self:getVehicle():cpGetFieldPolygon() ~= nil
end

---@param resetFieldPosition boolean resets the field position near the vehicle.
function CpAIJobBaleFinder:applyCurrentState(vehicle, mission, farmId, isDirectStart, resetFieldPosition)
	CpAIJob.applyCurrentState(self, vehicle, mission, farmId, isDirectStart)
	self.cpJobParameters:validateSettings()

	self:copyFrom(vehicle:getCpBaleFinderJob())
	local x, z = self.cpJobParameters.fieldPosition:getPosition()
	-- A direct reset must locate the field near the vehicle instead of retaining
	-- the boundary from the previous job.
	if resetFieldPosition or x == nil or z == nil then
		self:setFieldPositionFromVehicle(vehicle, self.maxNearbyFieldDistance)
	end
end

function CpAIJobBaleFinder:setValues()
	CpAIJob.setValues(self)
	local vehicle = self.vehicleParameter:getVehicle()
	self.baleFinderTask:setVehicle(vehicle)
end

--- Called when parameters change, scan field
function CpAIJobBaleFinder:validate(farmId)
	local isValid, isRunning, errorMessage = CpAIJob.validate(self, farmId)
	if not isValid then
		return isValid, errorMessage
	end
	local vehicle = self.vehicleParameter:getVehicle()
	if vehicle then 
		vehicle:applyCpBaleFinderJobParameters(self)
	end
	--------------------------------------------------------------
	--- Validate field setup
	--------------------------------------------------------------
	isValid, isRunning, errorMessage = self:detectFieldBoundary(isValid, errorMessage)
	-- if the field detection is still running, it's ok
	return isValid or isRunning, errorMessage
end

function CpAIJobBaleFinder:onFieldBoundaryDetectionFinished(vehicle, fieldPolygon, islandPolygons)
	if fieldPolygon then
		self.selectedFieldPlot:setWaypoints(fieldPolygon)
		self.selectedFieldPlot:setVisible(true)
		self:callFieldBoundaryDetectionFinishedCallback(true)
	else
		self.selectedFieldPlot:setVisible(false)
		self:callFieldBoundaryDetectionFinishedCallback(false, 'CP_error_field_detection_failed')
	end
end

function CpAIJobBaleFinder:draw(map, isOverviewMap)
	CpAIJob.draw(self, map, isOverviewMap)
	if not isOverviewMap then
		self.selectedFieldPlot:draw(map)
	end
end

--- Gets the additional task description shown.
function CpAIJobBaleFinder:getDescription()
	local desc = CpAIJob.getDescription(self)
	local currentTask = self:getTaskByIndex(self.currentTaskIndex)
    if currentTask == self.driveToTask then
		desc = desc .. " - " .. g_i18n:getText("ai_taskDescriptionDriveToField")
	elseif currentTask == self.baleFinderTask then
		local vehicle = self:getVehicle()
		if vehicle and AIUtil.hasChildVehicleWithSpecialization(vehicle, BaleWrapper) then
			desc = desc .. " - " .. g_i18n:getText("CP_ai_taskDescriptionWrapsBales")
		else 
			desc = desc .. " - " .. g_i18n:getText("CP_ai_taskDescriptionCollectsBales")
		end
	end
	return desc
end
