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

import { BreadData, FilesData, FileDataSource } from '../../../databases/model/FileData';
import { TopBar } from '../../component/common/TopBar';
import { BreadCrumb } from '../../component/myphone/BreadCrumb';
import { FilesList } from '../../component/myphone/FilesList';
import { setSystemBar, setImmersion } from '../../../base/utils/Common';
import router from '@ohos.router';
import FileAccessExec from '../../../base/utils/FileAccessExec';
import { SystemBarColor } from '../../../base/constants/UiConstant';
import { getResourceString } from '../../../base/utils/Tools';
import { TopOperateBar } from '../../component/common/TopOperateBar';
import { FileMkdirDialog } from '../../component/dialog/FileMkdirDialog';
import { Loading } from '../../component/common/Loading';
import { getMediaType, getDurationByUri } from '../../../databases/model/FileAssetModel';
import Logger from '../../../base/log/Logger';
import multimedia_image from '@ohos.multimedia.image';
import AbilityCommonUtil, { ResultCodePicker } from '../../../base/utils/AbilityCommonUtil';
import ObjectUtil from '../../../base/utils/ObjectUtil';
import StringUtil from '../../../base/utils/StringUtil';
import { FileUtil } from '../../../base/utils/FileUtil';
import fileAccess from '@ohos.file.fileAccess';
import { StartModeOptions } from '../../../base/model/StartModeOptions';
import { FilePickerUtil } from '../../../base/utils/FilePickerUtil';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

const TAG = 'myPhone';
let storage = LocalStorage.getShared();

@Entry(storage)
@Component
struct MyPhone {
  /**
   * 正在加载
   */
  private startModeOptions: StartModeOptions = FilePickerUtil.getStartOptionsFromStorage();
  @State isShowLoading: boolean = true;
  /**
   * 文件或文件夹数据
   */
  @State fileListSource: FileDataSource = new FileDataSource();
  /**
   * 面包屑
   */
  @State @Watch('onDireListChange') direList: BreadData[] = [];
  @State selectFilesList: FilesData[] = [];
  @State isMulti: boolean = false;
  @State selectAll: boolean = false;
  @State @Watch('checkedNumChange') checkedNum: number = 0;
  @Provide isList: boolean = true;
  @State selectName: string = '';
  @State fileSize: number = 0;
  fileMkdirDialog: CustomDialogController = new CustomDialogController({
    builder: FileMkdirDialog({
      fileItems: this.fileListSource.getDataArray(),
      getCurrentDir: this.getCurrentDirUri(),
      confirm: this.refreshData.bind(this)
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -80 }
  });

  checkedNumChange(): void {
    this.selectAll = this.checkedNum === this.fileListSource.totalCount();
    this.selectFilesList = this.fileListSource.getSelectedFileList();
    this.fileSize = 0;
    this.selectFilesList.forEach(item => {
      this.fileSize += item.size;
    });
  }

  getCurrentDirUri(): string {
    if (this.direList.length) {
      const lastBread = this.direList[this.direList.length-1];
      return lastBread.url;
    } else if (globalThis.documentInfo) {
      return globalThis.documentInfo.uri;
    } else {
      Logger.e(TAG, 'currentDir uri is null');
      return '';
    }
  }

  async getBreadCrumb(data: string): Promise<void> {
    if (!data) {
      data = '';
    }
    if (FileUtil.isUriPath(data)) {
      let fileHelper = await FileUtil.getFileAccessHelperAsync(globalThis.abilityContext);
      // 将uri转换成相对路径
      let curFileInfo: fileAccess.FileInfo = await FileUtil.getFileInfoByUri(data, fileHelper);
      if (!ObjectUtil.isNullOrUndefined(curFileInfo)) {
        data = FileUtil.getCurrentDir(curFileInfo.relativePath, FileUtil.isFolder(curFileInfo.mode));
      }
    }
    data = FileUtil.getPathWithFileSplit(data);

    let fileIterator: fileAccess.FileInfo | fileAccess.RootInfo | undefined = undefined;
    let fileData: FilesData[];
    let isContinue: boolean = true;
    let isRoot: boolean = true;
    while (isContinue) {
      isContinue = false;
      if (!fileIterator) {
        fileData = FileAccessExec.getRootFolder();
        isRoot = true;
      } else {
        fileData = FileAccessExec.getFileByCurIterator(fileIterator);
        isRoot = false;
      }
      if (Array.isArray(fileData)) {
        isContinue = true;
        for (let i = 0; i < fileData.length; i++) {
          let fileName: string = fileData[i].fileName;
          let currentDir: string = FileUtil.getPathWithFileSplit(fileData[i].currentDir);
          if (data.startsWith(currentDir)) {
            if (fileData[i].isFolder) {
              let bread: BreadData = { title: fileName, url: fileData[i].uri, fileIterator: fileData[i].fileIterator }
              this.direList.push(bread);
              fileIterator = fileData[i].fileIterator;
              if (data === currentDir) {
                isContinue = false;
              } else {
                break;
              }
            }
          }
        }
      }
      if (isRoot && !fileIterator) {
        isContinue = false;
      }
    }
    if (fileIterator) {
      fileData = FileAccessExec.getFileByCurIterator(fileIterator);
      this.fileListSource.setData(fileData);
    } else {
      this.getRootListFile();
    }
  }

  onPageShow() {
    // 文件选择器并且是多选模式下详情返回不更新，避免原有多选被重置
    if (this.isMulti) {
      return;
    }
    setImmersion(false);
    setSystemBar(SystemBarColor.WHITE, SystemBarColor.WHITE, SystemBarColor.BLACK, SystemBarColor.BLACK);
  }

  getRootListFile() {
    let fileList = FileAccessExec.getRootFolder();
    this.fileListSource.setData(fileList);
    this.getVideoAudioDuration(fileList);
  }

  getListFile(fileInfo: fileAccess.FileInfo | fileAccess.RootInfo) {
    let fileList = FileAccessExec.getFileByCurIterator(fileInfo);
    this.fileListSource.setData(fileList);
    this.getVideoAudioDuration(fileList);
  }

  async getVideoAudioDuration(fileList: FilesData[]) {
    const videoAudioList = fileList.filter(item => item.mimeTypeObj?.isVideo() || item.mimeTypeObj?.isAudio());
    for (let item of videoAudioList) {
      const mediaType: photoAccessHelper.PhotoType = getMediaType(item.fileName);
      await getDurationByUri(mediaType, item.uri).then((duration) => {
        item.duration = duration;
        let index = this.fileListSource.getIndex(item.uri);
        if (index >= 0) {
          this.fileListSource.replaceData(index, item);
        }
      })
    }
  }

  addCallBack() {
    this.fileMkdirDialog.open();
  }

  initData(): void {
    this.selectFilesList = [];
    this.selectAll = false;
    this.isMulti = false;
    this.checkedNum = 0;
    // 全部数据列表的isChecked置为false
    this.fileListSource.selectAll(false);
  }

  backCallback(): void {
    if (!this.isMulti) {
      AbilityCommonUtil.terminateFilePicker([], ResultCodePicker.SUCCESS, this.startModeOptions);
    } else {
      this.initData();
    }
  }

  menuCallback(): void {
    this.selectAll = !this.selectAll;
    this.fileListSource.selectAll(this.selectAll);
    if (this.selectAll) {
      this.checkedNum = this.fileListSource.totalCount();
    } else {
      this.checkedNum = 0;
      this.selectFilesList = [];
    }
  }

  refreshData() {
    if (this.direList.length) {
      const lastBread = this.direList[this.direList.length-1];
      if (lastBread.fileIterator !== undefined) {
        this.getListFile(lastBread.fileIterator);
      }
    } else {
      this.getRootListFile();
    }
  }

  aboutToAppear(): void {
    // 激活image媒体库，能够读取缩略图pixelMap
    multimedia_image.createPixelMap(new ArrayBuffer(4096), { size: { height: 1, width: 2 } }).then((pixelMap) => {
    })
    this.setShowLoading(true);
    let pickPath = this.getParams(this.startModeOptions);
    if (StringUtil.isEmpty(pickPath)) {
      this.getRootListFile();
    } else {
      this.getBreadCrumb(pickPath);
    }
    this.setShowLoading(false);
  }

  aboutToDisappear() {
  }

  getParams(startModeOptions: StartModeOptions): string {
    let defaultPickPath = startModeOptions.defaultFilePathUri;
    if (!ObjectUtil.isNullOrUndefined(defaultPickPath)) {
      return defaultPickPath;
    }
    let params = router.getParams() as Record<string, string>;
    if (!ObjectUtil.isNullOrUndefined(params)) {
      defaultPickPath = params.path as string;
      if (!ObjectUtil.isNullOrUndefined(defaultPickPath)) {
        return defaultPickPath;
      }
    }
    return '';
  }

  onDireListChange(): void {
    if (this.isMulti) {
      this.backCallback();
    }
    this.setShowLoading(true);
    if (this.direList.length) {
      const lastBreadCrumb = this.direList[this.direList.length-1];
      if (lastBreadCrumb.fileIterator !== undefined) {
        this.getListFile(lastBreadCrumb.fileIterator);
      }
    } else {
      this.getRootListFile();
    }
    this.setShowLoading(false);
    Logger.i(TAG, 'onDireListChange BreadCrumb length:' + this.direList.length);
  }

  setShowLoading(isShow: boolean) {
    this.isShowLoading = isShow;
  }

  onBackPress() {
    const direList = this.direList;
    const dirLen = this.direList.length;
    if (this.isMulti) {
      this.initData();
      return true;
    } else {
      if (router.getParams()) {
        router.back();
      } else {
        if (dirLen) {
          direList.splice(-1, 1);
          if (direList.length) {
            const lastDir = direList[direList.length-1];
            if (lastDir.fileIterator !== undefined) {
              this.getListFile(lastDir.fileIterator);
            }
          } else {
            this.getRootListFile();
          }
        } else {
          AbilityCommonUtil.terminateFilePicker([], ResultCodePicker.CANCEL, this.startModeOptions);
        }
      }
      return true;
    }
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
    Column() {
      // 头部导航
      TopBar({
        startModeOptions: this.startModeOptions,
        title: getResourceString($r('app.string.myPhone')),
        isMulti: this.isMulti,
        selectAll: this.selectAll,
        checkedNum: $checkedNum,
        checkedList: $selectFilesList,
        backCallback: this.backCallback.bind(this),
        menuCallback: this.menuCallback.bind(this)
      })
      // 面包屑
      BreadCrumb({
        direList: $direList
      })

      TopOperateBar({
        isDisabled: this.isMulti,
        addFolder: this.addCallBack.bind(this)
      })

      Column() {
        Loading({ isLoading: !!this.isShowLoading })
        if (!this.isShowLoading) {
          // 文件列表
          FilesList({
            startModeOptions: this.startModeOptions,
            fileListSource: $fileListSource,
            direList: $direList,
            isMulti: $isMulti,
            checkedNum: $checkedNum
          })
        }
      }.layoutWeight(1)
    }
    .width('100%')
  }
}