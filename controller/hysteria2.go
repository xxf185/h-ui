package controller

import (
	"encoding/base64"
	"fmt"
	"github.com/gin-gonic/gin"
	"github.com/skip2/go-qrcode"
	"h-ui/model/constant"
	"h-ui/model/dto"
	"h-ui/model/entity"
	"h-ui/model/vo"
	"h-ui/service"
	"h-ui/util"
	"net/url"
	"os"
	"strings"
	"time"
)

func Hysteria2Auth(c *gin.Context) {
	hysteria2AuthDto, err := validateField(c, dto.Hysteria2AuthDto{})
	if err != nil {
		return
	}
	id, username, err := service.Hysteria2Auth(*hysteria2AuthDto.Auth)
	if err != nil || username == "" {
		vo.Hysteria2AuthFail("", c)
		return
	}

	// 更新最近连接时间
	now := time.Now().UnixMilli()
	if err = service.UpdateAccount(entity.Account{
		BaseEntity: entity.BaseEntity{Id: &id},
		ConAt:      &now,
	}); err != nil {
		vo.Fail(err.Error(), c)
		return
	}
	vo.Hysteria2AuthSuccess(username, c)
}

func Hysteria2Kick(c *gin.Context) {
	hysteria2KickDto, err := validateField(c, dto.Hysteria2KickDto{})
	if err != nil {
		return
	}
	err = service.Hysteria2Kick(hysteria2KickDto.Ids, *hysteria2KickDto.KickUtilTime)
	if err != nil {
		vo.Fail(err.Error(), c)
		return
	}
	vo.Success(nil, c)
}

func Hysteria2ChangeVersion(c *gin.Context) {
	hysteria2VersionDto, err := validateField(c, dto.Hysteria2VersionDto{})
	if err != nil {
		return
	}

	running := service.Hysteria2IsRunning()
	if running {
		vo.Fail("please stop hysteria2 first", c)
		return
	}

	if util.Exists(util.GetHysteria2BinPath()) {
		if err := os.Remove(util.GetHysteria2BinPath()); err != nil {
			vo.Fail("filed remove hysteria2 bin file", c)
			return
		}
	}

	if err = util.DownloadHysteria2(fmt.Sprintf("app/%s", *hysteria2VersionDto.Version)); err != nil {
		vo.Fail(err.Error(), c)
		return
	}

	vo.Success(nil, c)
}

func ListRelease(c *gin.Context) {
	releases, err := util.ListRelease("apernet", "hysteria")
	if err != nil {
		vo.Fail("get hysteria2 releases failed", c)
		return
	}

	var versions []string
	for _, item := range releases {
		versionSplit := strings.Split(*item.TagName, "/v")
		if len(versionSplit) == 2 {
			// >= v2.4.4
			result := util.CompareVersion(versionSplit[1], "2.4.4")
			if result < 0 {
				break
			}
			for _, asset := range item.Assets {
				if asset.GetName() == util.GetHysteria2BinName() {
					versions = append(versions, fmt.Sprintf("v%s", versionSplit[1]))
					break
				}
			}
		}
	}
	vo.Success(versions, c)
}

func Hysteria2Url(c *gin.Context) {
	hysteria2UrlDto, err := validateField(c, dto.Hysteria2UrlDto{})
	if err != nil {
		return
	}

	url, err := service.Hysteria2Url(*hysteria2UrlDto.AccountId, *hysteria2UrlDto.Hostname)
	if err != nil {
		vo.Fail(err.Error(), c)
		return
	}
	// 生成二维码
	qrCode, err := qrcode.Encode(url, qrcode.Medium, 300)
	if err != nil {
		vo.Fail(err.Error(), c)
		return
	}
	hysteria2UrlVo := vo.Hysteria2UrlVo{
		Url:    url,
		QrCode: qrCode,
	}
	vo.Success(hysteria2UrlVo, c)
}

func Hysteria2SubscribeUrl(c *gin.Context) {
	hysteria2SubscribeUrlDto, err := validateField(c, dto.Hysteria2SubscribeUrlDto{})
	if err != nil {
		return
	}
	subscribeUrl, err := service.Hysteria2SubscribeUrl(*hysteria2SubscribeUrlDto.AccountId,
		*hysteria2SubscribeUrlDto.Protocol,
		*hysteria2SubscribeUrlDto.Host)
	if err != nil {
		vo.Fail(err.Error(), c)
		return
	}
	qrCode, err := qrcode.Encode(subscribeUrl, qrcode.Medium, 300)
	if err != nil {
		vo.Fail(err.Error(), c)
		return
	}
	subscribeVo := vo.Hysteria2SubscribeVo{
		Url:    subscribeUrl,
		QrCode: qrCode,
	}
	vo.Success(subscribeVo, c)
}

func Hysteria2Subscribe(c *gin.Context) {
	conPass := c.Param("conPass")
	conPass, err := url.QueryUnescape(conPass)
	if err != nil {
		vo.Fail("url decode err", c)
		return
	}
	userAgent := strings.ToLower(c.Request.Header.Get("User-Agent"))
	host := c.Request.Host

	if host == "" {
		vo.Fail("Host is empty", c)
		return
	}

	var clientType string
	if strings.Contains(userAgent, constant.Shadowrocket) {
		clientType = constant.Shadowrocket
	} else if strings.Contains(userAgent, constant.Clash) {
		clientType = constant.Clash
	} else if strings.Contains(userAgent, constant.V2rayN) {
		clientType = constant.V2rayN
	} else if strings.Contains(userAgent, constant.NekoBox) {
		clientType = constant.NekoBox
	} else {
		clientType = constant.Clash
	}

	userInfo, configStr, err := service.Hysteria2Subscribe(conPass, clientType, host)
	if err != nil {
		vo.Fail(err.Error(), c)
		return
	}

	if clientType == constant.Shadowrocket || clientType == constant.Clash {
		c.Header("content-disposition", "attachment; filename=hui.yaml")
		c.Header("profile-update-interval", "12")
		c.Header("subscription-userinfo", userInfo)
	} else if clientType == constant.V2rayN {
		configStr = base64.StdEncoding.EncodeToString([]byte(configStr))
	}

	c.String(200, configStr)
}
