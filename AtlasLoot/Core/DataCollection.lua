-- DataGathering provides functions for automated gathering of info on items and spells
AtlasLootDataCollection = {Spells = {}, Items = {}}

local BabbleEpoch = AtlasLoot_GetLocaleLibBabble("LibBabble-Epoch-3.0");
local TIME_BETWEEN_UPDATES = 0.25; -- How many seconds to wait between each update from the updateFunctionQueue
local MAX_QUERY_ATTEMPTS = 4; -- How many times we try adding each item to the tooltip before giving up.
local NOTIFY_INTERVAL = 50; -- Number of items scanned per notification on scanning progress.

local itemIDList = {};
local spellIDList = {};
local itemNameList = {};
local updateFunctionQueue = {};
local updateFrame = CreateFrame("Frame"); -- Fake frame for access to OnUpdate
local lastUpdateTime = 0.0; -- The value of GetTime() when we last ran a task from the updateFunctionQueue.
 -- Fake tooltip frame used for querying item info from the server.
local tooltipFrame = CreateFrame('GameTooltip', 'ALFakeTooltip', nil, 'GameTooltipTemplate');
tooltipFrame:SetOwner(UIParent, "ANCHOR_NONE");
local scans = 0; -- How many items or spells have been scanned so far.
local itemFails = 0; -- How many items we failed to find information for.
local spellFails = 0;-- How many spells we failed to find information for.


updateFrame:SetScript("OnUpdate", function()
	if GetTime() > lastUpdateTime + TIME_BETWEEN_UPDATES then
		nextTask = table.remove(updateFunctionQueue, 1);
		if nextTask then
			nextTask.fn(unpack(nextTask.args));
			lastUpdateTime = GetTime();

			if nextTask.args[2] == 1 then scans = scans + 1 end
			if NOTIFY_INTERVAL > 1 and scans % NOTIFY_INTERVAL == 0 then
				local remainingScans = #itemIDList + #itemNameList + #spellIDList - scans;
				print("Scanned "..scans.." items. "..remainingScans.." remaining...")
			end
		end
	end
end)

function GetToolTipText()
	local tooltipText = "";
	local tooltipRegions = tooltipFrame:GetRegions();
    for _, region in ipairs(tooltipRegions) do
	    if region and region:GetObjectType() == "FontString" then
	    	local regionText = region:GetText();
	    	if regionText then
	        	tooltipText = tooltipText..regionText;
	        end
	    end
	end
    return tooltipText;
end


function AtlasLoot:CancelDataCollection()
	updateFunctionQueue = {};
	print(BabbleEpoch["Data collection stopped."]);
end


function AtlasLoot:CollectDBInfo()
	AtlasLoot_LoadAllModules();

	itemIDList = {};
	spellIDList = {};
	itemNameList = {};
	local itemIDSet = {};
	local spellIDSet = {};
	scans = 0;
	itemFails = 0;
	spellFails = 0;

	-- Gather all unique Item IDs
	for dataID, data in pairs(AtlasLoot_Data) do
		for _, v in ipairs(data) do
			local ID = v[2];
			if type(ID) == "string" and ID:match("^[sS]%d%d%d") then
				spellIDSet[ID] = true;
			elseif ID == 0 or ID == 99999 then
				-- Ignore items with no ID but an icon, these are usually category names
				-- If there's no icon, then this is probably a real item but the ID
				-- hasn't been discovered yet. Try searching it by name instead.
				if v[3] == "" then
					local itemName = v[4];
					itemName = gsub(itemName, "=.-=", ""); -- Strip color codes
					table.insert(itemNameList, itemName);
				end
			else
				if type(ID) == "number" and ID > 0 and ID < 100000 then
					itemIDSet[ID] = true;
				end
			end
		end
	end

	for ID, _ in pairs(itemIDSet) do
		table.insert(itemIDList, ID);
	end
	table.sort(itemIDList);

	for ID, _ in pairs(spellIDSet) do
		table.insert(spellIDList, ID);
	end
	table.sort(spellIDList);

	table.sort(itemNameList);
	print("Scanning data for "..#itemIDList + #itemNameList.." items and "..#spellIDList.." spells...")

	table.insert(updateFunctionQueue, {fn = CollectItemInfoRecursive, args = {itemIDList, 1, 1}});
	table.insert(updateFunctionQueue, {fn = CollectSpellInfoRecursive, args = {spellIDList, 1, 1}});
	table.insert(updateFunctionQueue, {fn = CollectItemInfoRecursive, args = {itemNameList, 1, 1}});
end


function CollectItemInfoRecursive(list, index, attempt)
	searchTerm = list[index];
	if searchTerm == nil then 
		-- End of list, halt recursion
		--if list == itemIDList then
		--	local totalItems = #itemIDList + #itemNameList;
		--	print("Finished scanning items.");
		--	print("Found data for "..totalItems - itemFails.." items.");
		--	print("Failed to find data for "..itemFails.." items.");
		--end
		return 
	end

	local result = {}
	local ID = nil
	if type(searchTerm) == "number" then
		ID = searchTerm;
	end
	-- Try to collect item info
	if ID then
		tooltipFrame:ClearLines();
		tooltipFrame:SetHyperlink("item:"..ID);
	end
	-- Save everything returned by GetItemInfo()
	result.name, result.link, result.quality, result.iLevel, 
	result.reqLevel, result.class, result.subclass, result.maxBagStacks, 
	result.equipSlot, result.texture, result.vendorPrice = GetItemInfo(searchTerm);
	-- Save the allowable classes
	local classes = {}
	local tooltipText = GetToolTipText();
	local classText = tooltipText:match("[cC]lasse?s?:(.-\n)");
	if classText then
		for class in classText:gmatch("%a+") do
		  table.insert(classes, class);
		end
		result.allowedClasses = classes;
	end
	-- Save all modified stats (note: this might include enchants & feral DPS)
	if result.link then
		result.stats = GetItemStats(result.link);
	end
	-- Save the whole tooltip
	result.tooltip = tooltipText;

	if result.name ~= nil then
		if not ID then
			-- Item's ID was previously unknown, get the ID from the hyperlink.
			ID = result.link:match("item:(%d+)");
			ID = tonumber(ID);
		end
		if ID then
			AtlasLootDataCollection["Items"][ID] = result;
			if ATLASLOOT_DEBUGMESSAGES then
				print("Collected info for item "..result.name.." ("..ID..")");
			end
		else
			if ATLASLOOT_DEBUGMESSAGES then
				print("Collected info for item "..result.name.." but couldn't get its ID.");
			end
			itemFails = itemFails + 1;
		end
		-- We got our info, move on to the next item
		table.insert(updateFunctionQueue, {fn = CollectItemInfoRecursive, args = {list, index + 1, 1}});
	else
		if ID and attempt <= MAX_QUERY_ATTEMPTS then
			table.insert(updateFunctionQueue, {fn = CollectItemInfoRecursive, args = {list, index, attempt + 1}});
			if ATLASLOOT_DEBUGMESSAGES then
				print("Retry attempt #"..list.attempts[index].." for "..searchTerm);
			end
		else
			-- Couldn't get any info, move on to the next item.
			if ATLASLOOT_DEBUGMESSAGES then
				print("Failed to get item info for "..searchTerm..".");
			end
			itemFails = itemFails + 1;
			table.insert(updateFunctionQueue, {fn = CollectItemInfoRecursive, args = {list, index + 1, 1}});
		end
	end

	---- Notify of item scanning progress.
	--if NOTIFY_INTERVAL > 1 and attempt == 1 then
	--	local itemIDScanned = nil;
	--	local itemNameScanned = nil;
	--	if list == itemIDList then 
	--		itemIDScanned = index;
	--	else
	--		for _, task in ipairs(updateFunctionQueue) do
	--			if task.args[1] == itemIDList then
	--				itemIDScanned = task.args[2];
	--				break;
	--			end
	--		end
	--	end
	--	if list == itemNameList then
	--		itemNameScanned = index;
	--	else
	--		for _, task in ipairs(updateFunctionQueue) do
	--			if task.args[1] == itemNameList then
	--				itemNameScanned = task.args[2];
	--				break;
	--			end
	--		end
	--	end
	--	if not itemIDScanned then itemIDScanned = #itemIDList end
	--	if not itemNameScanned then itemNameScanned = #itemNameList end

	--	local totalItemsScanned = itemIDScanned + itemNameScanned;
	--	if totalItemsScanned % NOTIFY_INTERVAL == 0 then
	--		print("Scanned "..totalItemsScanned.." items...");
	--	end
	--end
end


function CollectSpellInfoRecursive(list, index, attempt)
	searchTerm = list[index]
	if searchTerm == nil then
		-- End of list, halt recursion
		local totalSpells = #spellIDList;
		print("Finished scanning spells.");
		print("Found data for "..totalSpells - spellFails.." spells.");
		print("Failed to find data for "..spellFails.." spells.");
	 	return
	end

	local result = {}
	local ID = nil
	ID = strsub(searchTerm, 2, #searchTerm);
	ID = tonumber(ID);
	if ID then
		tooltipFrame:ClearLines();
		tooltipFrame:SetHyperlink("spell:"..ID);

		result.name, result.rank, result.icon, result.powerCost, 
		result.isFunnel, result.powerType, result.castingTime, 
		result.minRange, result.maxRange = GetSpellInfo(ID);

		result.tooltip = GetToolTipText();
	else
		if ATLASLOOT_DEBUGMESSAGES then
			print("invalid spell ID: "..searchTerm);
		end
		spellFails = spellFails + 1;
	end

	if ID and result.name ~= nil then
		AtlasLootDataCollection["Spells"][ID] = result;
		if ATLASLOOT_DEBUGMESSAGES then
			print("Collected info for spell "..result.name.." ("..ID..")");
		end
		-- We got our info, move on to the next spell
		table.insert(updateFunctionQueue, {fn = CollectSpellInfoRecursive, args = {list, index + 1, 1}});
	else
		if ID and attempt <= MAX_QUERY_ATTEMPTS then
			table.insert(updateFunctionQueue, {fn = CollectSpellInfoRecursive, args = {list, index, attempt + 1}});
			if ATLASLOOT_DEBUGMESSAGES then
				print("Retry attempt #"..list.attempts[index].." for "..searchTerm);
			end
		else
			-- Couldn't get any info, move on to the next spell.
			if ATLASLOOT_DEBUGMESSAGES then
				print("Failed to get spell info for ID "..searchTerm..".");
			end
			spellFails = spellFails + 1;
			table.insert(updateFunctionQueue, {fn = CollectSpellInfoRecursive, args = {list, index + 1, 1}});
		end
	end

	---- Notify of spell scanning progress.
	--local totalSpellsScanned = index;
	--if NOTIFY_INTERVAL > 1 and attempt <= 2 and totalSpellsScanned % NOTIFY_INTERVAL == 0 then
	--	print("Scanned "..totalSpellsScanned.." spells...")
	--end
end
