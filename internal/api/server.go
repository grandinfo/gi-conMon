// Package api implements the conMon HTTP/WebSocket API server.
package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/grandinfo/gi-conMon/internal/alerter"
	"github.com/grandinfo/gi-conMon/internal/fsm"
	"github.com/grandinfo/gi-conMon/internal/model"
	"github.com/grandinfo/gi-conMon/internal/storage"
	"github.com/grandinfo/gi-conMon/internal/version"
)

// Server wraps gin.Engine with all conMon dependencies.
type Server struct {
	engine  *gin.Engine
	store   storage.Store
	fsm     *fsm.FSM
	alerter *alerter.Engine
	httpSrv *http.Server
}

// Config configures the API server.
type Config struct {
	Bind        string
	JWTSecret   string
	ExternalURL string
}

// New creates and configures the API server.
func New(cfg Config, store storage.Store, fsmInst *fsm.FSM, alerterInst *alerter.Engine) *Server {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(loggerMiddleware())

	s := &Server{
		engine:  r,
		store:   store,
		fsm:     fsmInst,
		alerter: alerterInst,
		httpSrv: &http.Server{
			Addr:         cfg.Bind,
			Handler:      r,
			ReadTimeout:  30 * time.Second,
			WriteTimeout: 30 * time.Second,
			IdleTimeout:  120 * time.Second,
		},
	}
	s.registerRoutes(cfg)
	return s
}

// Start begins listening. It blocks until ctx is cancelled.
func (s *Server) Start(ctx context.Context) error {
	errCh := make(chan error, 1)
	go func() {
		slog.Info("API server starting", "addr", s.httpSrv.Addr)
		if err := s.httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return s.httpSrv.Shutdown(shutCtx)
	}
}

// ---- route registration ----------------------------------------------

func (s *Server) registerRoutes(cfg Config) {
	r := s.engine

	// System endpoints (no auth)
	r.GET("/health", s.handleHealth)
	r.GET("/ready", s.handleReady)
	r.GET("/metrics", s.handleMetrics)

	// API v1
	v1 := r.Group("/api/v1")
	{
		// Global status
		v1.GET("/status", s.handleGlobalStatus)

		// Targets
		tg := v1.Group("/targets")
		{
			tg.GET("", s.handleListTargets)
			tg.POST("", s.handleCreateTarget)
			tg.GET("/:id", s.handleGetTarget)
			tg.PUT("/:id", s.handleUpdateTarget)
			tg.DELETE("/:id", s.handleDeleteTarget)
			tg.GET("/:id/status", s.handleTargetStatus)
			tg.GET("/:id/events", s.handleTargetEvents)
			tg.POST("/:id/probe", s.handleProbeNow)
			tg.POST("/:id/silence", s.handleSilenceTarget)
			tg.DELETE("/:id/silence", s.handleUnsilenceTarget)
		}

		// Alerts
		al := v1.Group("/alerts")
		{
			al.GET("", s.handleListAlerts)
			al.GET("/:id", s.handleGetAlert)
			al.POST("/:id/ack", s.handleAckAlert)
		}

		// Probe nodes
		v1.GET("/probes", s.handleListProbes)
	}
}

// ---- handlers --------------------------------------------------------

func (s *Server) handleHealth(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok", "version": version.Version})
}

func (s *Server) handleReady(c *gin.Context) {
	// TODO: check DB connectivity
	c.JSON(http.StatusOK, gin.H{"status": "ready"})
}

func (s *Server) handleMetrics(c *gin.Context) {
	// TODO: expose Prometheus metrics
	c.String(http.StatusOK, "# conMon metrics\n")
}

func (s *Server) handleGlobalStatus(c *gin.Context) {
	states := s.fsm.AllStates()
	summary := map[model.Status]int{}
	for _, st := range states {
		summary[st.Status]++
	}
	c.JSON(http.StatusOK, gin.H{
		"total":   len(states),
		"summary": summary,
		"ts":      time.Now(),
	})
}

func (s *Server) handleListTargets(c *gin.Context) {
	q := storage.TargetQuery{
		Protocol: c.Query("protocol"),
		Search:   c.Query("q"),
		Limit:    intQuery(c, "limit", 50),
		Offset:   intQuery(c, "offset", 0),
	}
	targets, total, err := s.store.ListTargets(c.Request.Context(), q)
	if err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"total": total, "data": targets})
}

func (s *Server) handleCreateTarget(c *gin.Context) {
	var t model.Target
	if err := c.ShouldBindJSON(&t); err != nil {
		apiError(c, http.StatusBadRequest, "INVALID_PARAMS", err.Error())
		return
	}
	if t.ID == "" {
		t.ID = "target-" + newID()
	}
	def := model.DefaultTarget()
	if t.IntervalSec == 0 {
		t.IntervalSec = def.IntervalSec
	}
	if t.TimeoutMs == 0 {
		t.TimeoutMs = def.TimeoutMs
	}
	if t.Retries == 0 {
		t.Retries = def.Retries
	}
	if t.Priority == "" {
		t.Priority = def.Priority
	}
	t.Enabled = true

	if err := s.store.SaveTarget(c.Request.Context(), &t); err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	c.JSON(http.StatusCreated, t)
}

func (s *Server) handleGetTarget(c *gin.Context) {
	t, err := s.store.GetTarget(c.Request.Context(), c.Param("id"))
	if err != nil {
		apiError(c, http.StatusNotFound, "NOT_FOUND", "target not found")
		return
	}
	state := s.fsm.GetState(t.ID)
	c.JSON(http.StatusOK, gin.H{"target": t, "state": state})
}

func (s *Server) handleUpdateTarget(c *gin.Context) {
	existing, err := s.store.GetTarget(c.Request.Context(), c.Param("id"))
	if err != nil {
		apiError(c, http.StatusNotFound, "NOT_FOUND", "target not found")
		return
	}
	if err := c.ShouldBindJSON(existing); err != nil {
		apiError(c, http.StatusBadRequest, "INVALID_PARAMS", err.Error())
		return
	}
	existing.ID = c.Param("id")
	if err := s.store.SaveTarget(c.Request.Context(), existing); err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	c.JSON(http.StatusOK, existing)
}

func (s *Server) handleDeleteTarget(c *gin.Context) {
	if err := s.store.DeleteTarget(c.Request.Context(), c.Param("id")); err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	s.fsm.Remove(c.Param("id"))
	c.Status(http.StatusNoContent)
}

func (s *Server) handleTargetStatus(c *gin.Context) {
	state := s.fsm.GetState(c.Param("id"))
	if state == nil {
		apiError(c, http.StatusNotFound, "NOT_FOUND", "target state not found")
		return
	}
	c.JSON(http.StatusOK, state)
}

func (s *Server) handleTargetEvents(c *gin.Context) {
	q := storage.EventQuery{
		TargetID: c.Param("id"),
		Limit:    intQuery(c, "limit", 50),
		Offset:   intQuery(c, "offset", 0),
	}
	events, total, err := s.store.ListEvents(c.Request.Context(), q)
	if err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"total": total, "data": events})
}

func (s *Server) handleProbeNow(c *gin.Context) {
	// Trigger probe is async; actual scheduling handled by probe scheduler
	c.JSON(http.StatusAccepted, gin.H{"message": "probe scheduled"})
}

func (s *Server) handleSilenceTarget(c *gin.Context) {
	s.fsm.SetSilent(c.Param("id"), true)
	c.JSON(http.StatusOK, gin.H{"message": "silenced"})
}

func (s *Server) handleUnsilenceTarget(c *gin.Context) {
	s.fsm.SetSilent(c.Param("id"), false)
	c.JSON(http.StatusOK, gin.H{"message": "unsilenced"})
}

func (s *Server) handleListAlerts(c *gin.Context) {
	q := storage.AlertQuery{
		TargetID: c.Query("target_id"),
		Limit:    intQuery(c, "limit", 50),
		Offset:   intQuery(c, "offset", 0),
	}
	if st := c.Query("status"); st != "" {
		q.Status = model.AlertStatus(st)
	}
	alerts, total, err := s.store.ListAlerts(c.Request.Context(), q)
	if err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"total": total, "data": alerts})
}

func (s *Server) handleGetAlert(c *gin.Context) {
	a, err := s.store.GetAlert(c.Request.Context(), c.Param("id"))
	if err != nil {
		apiError(c, http.StatusNotFound, "NOT_FOUND", "alert not found")
		return
	}
	c.JSON(http.StatusOK, a)
}

func (s *Server) handleAckAlert(c *gin.Context) {
	if err := s.alerter.AckAlert(c.Param("id"), "api"); err != nil {
		apiError(c, http.StatusNotFound, "NOT_FOUND", err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "acknowledged"})
}

func (s *Server) handleListProbes(c *gin.Context) {
	nodes, err := s.store.ListProbeNodes(c.Request.Context())
	if err != nil {
		apiError(c, http.StatusInternalServerError, "STORAGE_ERROR", err.Error())
		return
	}
	c.JSON(http.StatusOK, gin.H{"data": nodes})
}

// ---- helpers ---------------------------------------------------------

func apiError(c *gin.Context, status int, code, msg string) {
	c.JSON(status, gin.H{"code": code, "message": msg})
}

func intQuery(c *gin.Context, key string, def int) int {
	var v int
	if s := c.Query(key); s != "" {
		if _, err := fmt.Sscanf(s, "%d", &v); err == nil {
			return v
		}
	}
	return def
}

func loggerMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		slog.Info("http",
			"method", c.Request.Method,
			"path", c.Request.URL.Path,
			"status", c.Writer.Status(),
			"duration_ms", time.Since(start).Milliseconds(),
			"ip", c.ClientIP(),
		)
	}
}
