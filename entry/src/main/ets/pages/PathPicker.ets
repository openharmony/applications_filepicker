/*
 * Copyright (c) 2021-2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { fileTree } from './component/dialog/FileMoveDialog';
import Logger from '../base/log/Logger';
import ErrorCodeConst from '../base//constants/ErrorCodeConst';
import { toast } from '../base/utils/Common';
import AbilityCommonUtil, { ResultCodePicker } from '../base/utils/AbilityCommonUtil';
import { SystemBarColor } from '../base/constants/UiConstant';
import StringUtil from '../base/utils/StringUtil';
import { FileUtil, ErrUri, ErrCodeMessage } from '../base/utils/FileUtil';
import ObjectUtil from '../base/utils/ObjectUtil';
import fileAccess from '@ohos.file.fileAccess';
import { ArrayUtil } from '../base/utils/ArrayUtil';
import { UiUtil } from '../base/utils/UiUtil';
import { StartModeOptions } from '../base/model/StartModeOptions';
import { FilePickerUtil } from '../base/utils/FilePickerUtil';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@ohos.base';
import { MoveCallBackParams } from '../databases/model/FileData'

const TAG = 'PathSelector';
let storage = LocalStorage.getShared();

@Entry(storage)
@Component
struct PathSelector {
  private startModeOptions: StartModeOptions = FilePickerUtil.getStartOptionsFromStorage();
  @State createResultType: number = ErrorCodeConst.PICKER.NORMAL;

  aboutToAppear() {
    UiUtil.setWindowBackground(SystemBarColor.LIGHT_GRAY);
  }

  async saveFileCallback(res: MoveCallBackParams, startModeOptions: StartModeOptions): Promise<void> {
    if (res?.cancel) {
      AbilityCommonUtil.terminatePathPicker([], ResultCodePicker.CANCEL, startModeOptions);
      return;
    } else {
      let fileNameList = this.startModeOptions.newFileNames;
      // 保存单个文件时文件名可修改，需使用修改后的文件名来创建文件
      if (fileNameList.length <= 1) {
        fileNameList = [res.fileName];
      }
      this.saveFiles(res.selectUri, fileNameList).then((createdFileList) => {
        AbilityCommonUtil.terminatePathPicker(createdFileList, ResultCodePicker.SUCCESS, startModeOptions);
      }).catch((err: BusinessError) => {
        let errorMessage = '';
        let errorCode = 0;
        Logger.e(TAG, JSON.stringify(err));
        if (err.code) {
          if (err.code === ErrorCodeConst.FILE_ACCESS.FILE_NAME_EXIST) {
            errorMessage = 'Same name file already exists';
            errorCode = ErrorCodeConst.PICKER.FILE_NAME_EXIST;
            this.createResultType = errorCode;
            const pathName = startModeOptions.newFileNames;
            let listLength: number = pathName.length;
            if (listLength == 1) {
              return;
            }
          } else if (err.code === ErrorCodeConst.FILE_ACCESS.FILE_NAME_INVALID) {
            errorMessage = 'Invalid display name';
            errorCode = ErrorCodeConst.PICKER.FILE_NAME_INVALID;
          } else {
            errorMessage = 'File create failed';
            errorCode = ErrorCodeConst.PICKER.OTHER_ERROR;
          }
        } else {
          errorMessage = err.message ? err.message : '';
          errorCode = ErrorCodeConst.PICKER.OTHER_ERROR;
        }
        AbilityCommonUtil.terminatePathPicker([], errorCode, startModeOptions);
        toast($r('app.string.save_file_fail'));
        Logger.e(TAG, `path select error, errorCode: ${errorCode}, errorMessage: ${errorMessage}`);
      })
    }
  }

  /**
   * PathPicker保存文件
   * @param data SaveFilesParam
   */
  async saveFiles(path: string, nameList: string[]): Promise<string[]> {
    return new Promise(async (resolve, reject) => {
      let fileAccessHelper = await FileUtil.getFileAccessHelperAsync(globalThis.abilityContext);
      let dirPath = path;
      if (StringUtil.isEmpty(dirPath)) {
        dirPath = (await FileUtil.getFileInfoByRelativePath('Documents/', fileAccessHelper)).uri;
      }
      let fileNameArr = nameList;
      let successArr: string[] = [];
      let resultErr: ErrCodeMessage = new ErrCodeMessage();
      let len: number = fileNameArr.length;
      let fileNameList: string[] = [];
      if (len > 1) {
        fileNameList = await this.getPickPathListFiles(dirPath, fileAccessHelper);
      }
      Logger.i(TAG, 'saveFiles createName: ' + JSON.stringify(fileNameArr) + ' ; ');
      Logger.i(TAG, 'saveFiles subList: ' + JSON.stringify(fileNameList) + ' ; ');
      for (let i = 0; i < len; i++) {
        const currName = fileNameArr[i];
        let result: ErrUri = new ErrUri();
        if (len === 1) {
          result = await FileUtil.createFile(fileAccessHelper, dirPath, currName);
        } else {
          result = await this.tryRenameFileOperate(fileAccessHelper, currName, dirPath, 0, fileNameList);
        }
        if (ObjectUtil.isUndefined(result.err)) {
          Logger.i(TAG, 'saveFiles createOK: ' + result.uri);
          successArr.push(result.uri);
          continue;
        }
        Logger.i(TAG, 'saveFiles err: ' + result.err.code);
        // 失败
        resultErr.code = result.err.code;
        resultErr.message = result.err.message;
        let photoManageHelper: photoAccessHelper.PhotoAccessHelper = AbilityCommonUtil.getPhotoManageHelper();
        if (ObjectUtil.isNullOrUndefined(photoManageHelper)) {
          break;
        }
        for (let i = 0; i < successArr.length; i++) {
          await FileUtil.hardDelete(successArr[i]);
        }
        try {
          photoManageHelper.release();
        } catch (e) {
          Logger.e(TAG, 'mediaLibrary close error');
        }
        successArr = [];
        break;
      }

      Logger.i(TAG, 'saveFiles end: ' + JSON.stringify(successArr));
      if (!ArrayUtil.isEmpty(successArr)) {
        resolve(successArr);
      } else {
        reject(resultErr);
      }
    })
  }

  private async getPickPathListFiles(dirUri: string, fileAccessHelper: fileAccess.FileAccessHelper): Promise<string[]> {
    let fileInfo: fileAccess.FileInfo = await FileUtil.getFileInfoByUri(dirUri, fileAccessHelper);
    if (ObjectUtil.isNullOrUndefined(fileInfo) || !FileUtil.isFolder(fileInfo.mode)) {
      return [];
    }
    return this.getFilesByIterator(fileInfo.listFile());
  }

  private getFilesByIterator(fileIterator: fileAccess.FileIterator): string[] {
    if (ObjectUtil.isNull(fileIterator)) {
      return [];
    }
    let result: string[] = [];
    let isDone = false;
    while (!isDone) {
      try {
        let nextFileInfo = fileIterator.next();
        isDone = nextFileInfo.done;
        if (isDone) {
          break;
        }
        let currFile = nextFileInfo.value;
        if (!FileUtil.isFolder(currFile.mode)) {
          result.push(currFile.fileName);
        }
      } catch (err) {
        Logger.e(TAG, 'current File err: ' + JSON.stringify(err) + ', ' + err.toString());
      }
    }
    return result;
  }

  private async tryRenameFileOperate(fileAccessHelper: fileAccess.FileAccessHelper, fileName: string,
    dirUri: string, renameCount: number, fileNameList: string[] = []): Promise<ErrUri> {
    let index = fileName.lastIndexOf('.');
    let name = fileName;
    let suffix = '';
    if (index !== -1) {
      suffix = fileName.substring(index, fileName.length);
      name = fileName.substring(0, index);
    }
    let hasReNameCount = FileUtil.getFileNameReName(name);
    if (!ObjectUtil.isNullOrUndefined(hasReNameCount)) {
      let num = Number(hasReNameCount[1]);
      if (!isNaN(num)) {
        name = hasReNameCount[0];
        renameCount = num;
      }
    }

    let newName = fileName;
    while (true) {
      newName = FileUtil.renameFile(name, renameCount++, suffix);
      let index = this.getIndex(newName, fileNameList);
      Logger.i(TAG, 'tryRenameFileOperate : ' + newName + ' ; index = ' + index);
      if (index === -1) {
        const result = await FileUtil.createFile(fileAccessHelper, dirUri, newName);
        if (ObjectUtil.isUndefined(result.err)) {
          Logger.i(TAG, 'tryRenameFileOperate createOK: ' + result.uri);
          return result;
        } else {
          Logger.i(TAG, 'tryRenameFileOperate createFail: ' + JSON.stringify(result) + ' ; ' + newName);
          if (result.err.code === ErrorCodeConst.FILE_ACCESS.FILE_NAME_EXIST) {
            fileNameList.push(newName);
          } else {
            return result;
          }
        }
      }
    }
  }

  private getIndex(fileName: string, fileNameList: string[] = []) {
    return fileNameList.findIndex(value => value === fileName);
  }

  build() {
    if (this.startModeOptions.isUxt()) {
      Column() {
      }.bindSheet(true, this.mainContent(), {
        height: '95%',
        dragBar: false,
        showClose: false,
        preferType: SheetType.CENTER,
        onAppear: () => {
        },
        shouldDismiss: () => {
          this.startModeOptions.session.terminateSelf();
        }
      })
    } else {
      this.mainContent()
    }
  }

  @Builder
  mainContent() {
    Row() {
      fileTree({
        startModeOptions: this.startModeOptions,
        createFileFailType: $createResultType,
        moveCallback: (e: MoveCallBackParams) => {
          this.saveFileCallback(e, this.startModeOptions);
        }
      })
    }
  }
}
