#include "bundle.h"
#include "base64.h"
#include "common.h"
#include "macho.h"
#include "sys/stat.h"
#include "sys/types.h"

ZBundle::ZBundle()
{
	m_pSignAssets = NULL;
	m_pSignAsset = NULL;
	m_bForceSign = false;
	m_bWeakInject = false;
	m_bRemoveProvision = false;
	m_bEnableDocuments = false;
	m_bRemoveExtensions = false;
	m_bRemoveWatchApp = false;
	m_bRemoveUISupportedDevices = false;
}

bool ZBundle::FindAppFolder(const string& strFolder, string& strAppFolder)
{
	if (ZFile::IsPathSuffix(strFolder, ".app") || ZFile::IsPathSuffix(strFolder, ".appex")) {
		strAppFolder = strFolder;
		return true;
	}

	ZFile::EnumFolder(strFolder.c_str(), true, [&](bool bFolder, const string& strPath) {
		string strName = ZUtil::GetBaseName(strPath.c_str());
		if ("__MACOSX" == strName) {
			return true;
		}
		return false;
	}, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				strAppFolder = strPath;
				return true;
			}
		}
		return false;
	});

	return (!strAppFolder.empty());
}

bool ZBundle::GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName)
{
	string strInfoPlistData;
	string strInfoPlistPath = strFolder + "/Info.plist";
	ZFile::ReadFile(strInfoPlistPath.c_str(), strInfoPlistData);

	jvalue jvInfo;
	jvInfo.read_plist(strInfoPlistData);
	string strBundleId = jvInfo["CFBundleIdentifier"];
	string strBundleExe = jvInfo["CFBundleExecutable"];
	string strBundleVersion = jvInfo["CFBundleVersion"];
	if (strBundleId.empty() || strBundleExe.empty()) {
		return false;
	}

	string strInfoSHA1;
	string strInfoSHA256;
	ZSHA::SHABase64(strInfoPlistData, strInfoSHA1, strInfoSHA256);

	jvNode["bundle_id"] = strBundleId;
	jvNode["bundle_version"] = strBundleVersion;
	jvNode["bundle_executable"] = strBundleExe;
	jvNode["sha1"] = strInfoSHA1;
	jvNode["sha256"] = strInfoSHA256;
	if (!jvNode.has("path")) {
		jvNode["path"] = strFolder.substr(m_strAppFolder.size() + 1);
	}

	if (bGetName) {
		string strBundleName = jvInfo["CFBundleDisplayName"];
		if (strBundleName.empty()) {
			strBundleName = jvInfo["CFBundleName"].as_cstr();
		}
		jvNode["name"] = strBundleName;
	}

	return true;
}

bool ZBundle::GetObjectsToSign(const string& strFolder, jvalue& jvInfo)
{
	vector<string> allBundles;
	
	std::function<void(const string&)> findAllBundles = [&](const string& currentPath) {
		ZFile::EnumFolder(currentPath.c_str(), false, NULL, [&](bool bFolder, const string& strPath) {
			if (bFolder) {
				if (ZFile::IsPathSuffix(strPath, ".app") ||
					ZFile::IsPathSuffix(strPath, ".appex") ||
					ZFile::IsPathSuffix(strPath, ".framework") ||
					ZFile::IsPathSuffix(strPath, ".xctest")) {
					allBundles.push_back(strPath);
					findAllBundles(strPath);
				} else {
					findAllBundles(strPath);
				}
			}
			return false;
		});
	};
	
	findAllBundles(strFolder);
	
	sort(allBundles.begin(), allBundles.end(), [](const string& a, const string& b) {
		size_t depthA = count(a.begin(), a.end(), '/');
		size_t depthB = count(b.begin(), b.end(), '/');
		// deeper paths first
		return depthA > depthB;
	});
	
	for (const string& bundlePath : allBundles) {
		jvalue jvNode;
		if (GetSignFolderInfo(bundlePath, jvNode)) {
			jvInfo["folders"].push_back(jvNode);
		}
	}
	
	ZFile::EnumFolder(strFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (bFolder || string::npos != strPath.find(".dSYM") ||
			string::npos != strPath.find("_WatchKitStub")) {
			return false;
		}
		bool bMachO = false;
		{
			FILE* fp = NULL;
#ifdef _WIN32
			fopen_s(&fp, strPath.c_str(), "rb");
#else
			fp = fopen(strPath.c_str(), "rb");
#endif
			if (fp) {
				uint32_t magic = 0;
				if (1 == fread(&magic, sizeof(magic), 1, fp)) {
					bMachO = (magic == MH_MAGIC || magic == MH_CIGAM ||
							  magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
							  magic == FAT_MAGIC || magic == FAT_CIGAM);
				}
				fclose(fp);
			}
		}
		if (bMachO) {
			jvInfo["files"].push_back(strPath.substr(m_strAppFolder.size() + 1));
		}
		return false;
	});
	
	return true;
}

bool ZBundle::GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes)
{
	set<string> setFiles;
	ZFile::EnumFolder(strFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (!bFolder) {
			string strNode = strPath.substr(strFolder.size() + 1);
			ZUtil::StringReplace(strNode, "\\", "/");
			setFiles.insert(strNode);
		}
		return false;
	});

	jvalue jvInfo;
	jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str());
	string strBundleExe = jvInfo["CFBundleExecutable"];

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	setFiles.erase("_CodeSignature/CodeResources");
	setFiles.erase(strBundleExe);
	
	jvCodeRes.clear();
	jvCodeRes["files"] = jvalue(jvalue::E_OBJECT);
	jvCodeRes["files2"] = jvalue(jvalue::E_OBJECT);

	for (string strKey : setFiles) {
		if (m_bRemoveProvision && strKey == "embedded.mobileprovision") {
			string strProvFile = strFolder + "/embedded.mobileprovision";
			remove(strProvFile.c_str());
			ZLog::Print(">>> Removed embedded.mobileprovision\n");
			continue;
		}

		string strFile = strFolder + "/" + strKey;
		string strSHA1Base64;
		string strSHA256Base64;
		ZSHA::SHABase64File(strFile.c_str(), strSHA1Base64, strSHA256Base64);

#ifdef _WIN32
		strKey = ic.A2U8(strKey);
#endif

		bool bomit1 = false;
		bool bomit2 = false;

		if (ZFile::IsPathSuffix(strKey, ".lproj/locversion.plist")) {
			bomit1 = true;
			bomit2 = true;
		}

		if (ZFile::IsPathSuffix(strKey, ".DS_Store") || "Info.plist" == strKey || "PkgInfo" == strKey) {
			bomit2 = true;
		}

		if (!bomit1) {
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files"][strKey]["hash"] = "data:" + strSHA1Base64;
				jvCodeRes["files"][strKey]["optional"] = true;
			} else {
				jvCodeRes["files"][strKey] = "data:" + strSHA1Base64;
			}
		}

		if (!bomit2) {
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strSHA1Base64;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strSHA256Base64;
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files2"][strKey]["optional"] = true;
			}
		}
	}

	jvCodeRes["rules"]["^.*"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules"]["^version.plist$"] = true;

	jvCodeRes["rules2"]["^.*"] = true;
	jvCodeRes["rules2"][".*\\.dSYM($|/)"]["weight"] = 11.0;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["omit"] = true;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["weight"] = 2000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules2"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules2"]["^Info\\.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^Info\\.plist$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^PkgInfo$"]["omit"] = true;
	jvCodeRes["rules2"]["^PkgInfo$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^embedded\\.provisionprofile$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^version\\.plist$"]["weight"] = 20.0;

	return true;
}

void ZBundle::GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles)
{
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			arrChangedFiles.push_back(jvNode["files"][i]);
		}
	}

	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			jvalue& jvSubNode = jvNode["folders"][i];
			GetChangedFiles(jvSubNode, arrChangedFiles);
			string strPath = jvSubNode["path"];
			arrChangedFiles.push_back(strPath + "/_CodeSignature/CodeResources");
			arrChangedFiles.push_back(strPath + "/" + jvSubNode["bundle_executable"].as_string());
		}
	}
}

void ZBundle::GetNodeChangedFiles(jvalue& jvNode, bool excludeProvisioning)
{
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			GetNodeChangedFiles(jvNode["folders"][i], excludeProvisioning);
		}
	}

	vector<string> arrChangedFiles;
	GetChangedFiles(jvNode, arrChangedFiles);
	for (size_t i = 0; i < arrChangedFiles.size(); i++) {
		jvNode["changed"].push_back(arrChangedFiles[i]);
	}
	
	if (excludeProvisioning) {
		if ("/" == jvNode["path"]) { // root
			jvNode["changed"].push_back("embedded.mobileprovision");
		}
	}
}

bool ZBundle::SignNode(jvalue& jvNode)
{
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			string strFile = jvNode["files"][i];
			ZLog::PrintV(">>> SignFile: \t%s\n", strFile.c_str());
			ZMachO macho;
			if (macho.InitV("%s/%s", m_strAppFolder.c_str(), strFile.c_str())) {
				macho.Sign(m_pSignAsset, m_bForceSign, "", "", "", "");
			} else {
				ZLog::WarnV(">>> Warning: Skipping non-Mach-O file: \t%s\n", strFile.c_str());
			}
		}
	}
	
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			if (!SignNode(jvNode["folders"][i])) {
				return false;
			}
		}
	}

	jbase64 b64;
	string strInfoSHA1;
	string strInfoSHA256;
	string strFolder = jvNode["path"];
	string strBundleId = jvNode["bundle_id"];
	string strBundleExe = jvNode["bundle_executable"];
	b64.decode(jvNode["sha1"].as_cstr(), strInfoSHA1);
	b64.decode(jvNode["sha256"].as_cstr(), strInfoSHA256);
	if (strBundleId.empty() || strBundleExe.empty() || strInfoSHA1.empty() ||
		strInfoSHA256.empty()) {
		ZLog::ErrorV(">>> Can't get BundleID or BundleExecute or Info.plist SHASum in Info.plist! %s\n", strFolder.c_str());
		return false;
	}

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	string strBaseFolder = m_strAppFolder;
	if ("/" != strFolder) {
		strBaseFolder += "/";
		strBaseFolder += strFolder;
	}

	string strExePath = strBaseFolder + "/" + strBundleExe;
	ZLog::PrintV(">>> SignFolder: %s, (%s)\n", ("/" == strFolder) ? ZUtil::GetBaseName(m_strAppFolder.c_str()) : strFolder.c_str(), strBundleExe.c_str());

	ZMachO macho;
	if (!macho.Init(strExePath.c_str())) {
		ZLog::ErrorV(">>> Can't parse BundleExecute file! %s\n", strExePath.c_str());
#if !TARGET_OS_IOS
		return false;
#else
		return true;
#endif
	}

	bool bForceSign = m_bForceSign;
	if ("/" == strFolder) { // inject/remove dylib before CodeResources generation
		for (const string& strDylibFile : m_arrInjectDylibs) {
			if (macho.InjectDylib(m_bWeakInject, strDylibFile.c_str())) {
				bForceSign = true;
			}
		}
		if (!m_setRemoveDylibs.empty()) {
			macho.RemoveDylibs(m_setRemoveDylibs);
			for (const string& name : m_setRemoveDylibs) {
				string baseName = name;
				if (baseName.find("@executable_path/") == 0) {
					baseName = baseName.substr(17);
				}
				ZFile::RemoveFileV("%s/%s", m_strAppFolder.c_str(), baseName.c_str());
			}
			bForceSign = true;
		}
	}

	if (m_pSignAssets) {
		// LocSign: pick this bundle's own profile by exact application identifier
		// ("<prefix>.<bundle id>") and embed it BEFORE CodeResources is generated,
		// so the bundle's resource seal covers the final profile bytes. Upstream
		// wrote it after sealing and matched by suffix.
		ZSignAsset* pMatched = NULL;
		for (auto it = m_pSignAssets->begin(); it != m_pSignAssets->end(); ++it) {
			const string& strAppId = it->m_strApplicationId;
			size_t pos = strAppId.find('.');
			if (string::npos != pos && strAppId.substr(pos + 1) == strBundleId) {
				pMatched = &(*it);
				break;
			}
		}
		if (NULL != pMatched) {
			m_pSignAsset = pMatched;
			if (!ZFile::WriteFileV(m_pSignAsset->m_strProvData, "%s/embedded.mobileprovision", strBaseFolder.c_str())) {
				ZLog::ErrorV(">>> Can't write embedded.mobileprovision!\n");
				return false;
			}
		} else if ("/" == strFolder || ZFile::IsPathSuffix(strBaseFolder, ".appex") || ZFile::IsPathSuffix(strBaseFolder, ".app")) {
			// An app or extension without its own profile cannot install.
			ZLog::ErrorV(">>> No provisioning profile for bundle: %s\n", strBundleId.c_str());
			return false;
		} else {
			// Frameworks have no profile; sign them with the main app's identity.
			m_pSignAsset = &m_pSignAssets->front();
		}
	}

	ZFile::CreateFolderV("%s/_CodeSignature", strBaseFolder.c_str());
	string strCodeResFile = strBaseFolder + "/_CodeSignature/CodeResources";

	jvalue jvCodeRes;
	if (!bForceSign) {
		jvCodeRes.read_plist_from_file(strCodeResFile.c_str());
	}

	if (bForceSign || jvCodeRes.is_null()) { // create
		if (!GenerateCodeResources(strBaseFolder, jvCodeRes)) {
			ZLog::ErrorV(">>> Create CodeResources failed! %s\n", strBaseFolder.c_str());
			return false;
		}
	} else if (jvNode.has("changed")) { // use existsed
		for (size_t i = 0; i < jvNode["changed"].size(); i++) {
			string strFile = jvNode["changed"][i].as_cstr();
			string strRealFile = m_strAppFolder + "/" + strFile;

			string strFileSHA1;
			string strFileSHA256;
			if (!ZSHA::SHABase64File(strRealFile.c_str(), strFileSHA1, strFileSHA256)) {
				ZLog::ErrorV(">>> Can't get changed file SHASum! %s", strFile.c_str());
				return false;
			}

			string strKey = strFile;
			if ("/" != strFolder) {
				strKey = strFile.substr(strFolder.size() + 1);
			}

			jvCodeRes["files"][strKey] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strFileSHA256;

			ZLog::DebugV("\t\tChanged file: %s, %s\n", strFileSHA1.c_str(), strKey.c_str());
		}
	}

	string strCodeResData;
	jvCodeRes.style_write_plist(strCodeResData);
	if (!ZFile::WriteFile(strCodeResFile.c_str(), strCodeResData)) {
		ZLog::ErrorV("\tWriting CodeResources failed! %s\n", strCodeResFile.c_str());
		return false;
	}

	if (!macho.Sign(m_pSignAsset, bForceSign, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResData)) {
		return false;
	}

	return true;
}

bool ZBundle::ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId)
{
	vector<string> arrFolders;
	ZFile::EnumFolder(m_strAppFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				arrFolders.push_back(strPath);
			}
		}
		return false;
	});

	for (const string& strFolder: arrFolders) {
		jvalue jvInfo;
		if (!jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str())) {
			ZLog::WarnV(">>> Can't find Plugin's Info.plist! %s\n", strFolder.c_str());
			continue;
		}

		string strOldPIBundleID = jvInfo["CFBundleIdentifier"];
		string strNewPIBundleID = strOldPIBundleID;
		ZUtil::StringReplace(strNewPIBundleID, strOldBundleId, strNewBundleId);
		jvInfo["CFBundleIdentifier"] = strNewPIBundleID;
		ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin\n", strOldPIBundleID.c_str(), strNewPIBundleID.c_str());

		if (jvInfo.has("WKCompanionAppBundleIdentifier")) {
			string strOldWKCBundleID = jvInfo["WKCompanionAppBundleIdentifier"];
			string strNewWKCBundleID = strOldWKCBundleID;
			ZUtil::StringReplace(strNewWKCBundleID, strOldBundleId, strNewBundleId);
			jvInfo["WKCompanionAppBundleIdentifier"] = strNewWKCBundleID;
			ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin-WKCompanionAppBundleIdentifier\n", strOldWKCBundleID.c_str(), strNewWKCBundleID.c_str());
		}

		if (jvInfo.has("NSExtension")) {
			if (jvInfo["NSExtension"].has("NSExtensionAttributes")) {
				if (jvInfo["NSExtension"]["NSExtensionAttributes"].has("WKAppBundleIdentifier")) {
					string strOldWKBundleID = jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"];
