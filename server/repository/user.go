package repository

import (
	"context"
	"errors"

	"github.com/commandlinecoding/elephant/server/config"
	"github.com/commandlinecoding/elephant/server/models"
	"github.com/jackc/pgx/v5"
)

type UserRepository struct{}

func NewUserRepository() *UserRepository {
	return &UserRepository{}
}

func (r *UserRepository) CreateUser(ctx context.Context, username, displayName, passwordHash string) (*models.User, error) {
	query := `
		INSERT INTO users (username, display_name, password_hash, created_at)
		VALUES ($1, $2, $3, NOW())
		RETURNING id, username, display_name, password_hash, created_at;
	`
	var user models.User
	err := config.DB.QueryRow(ctx, query, username, displayName, passwordHash).Scan(
		&user.ID,
		&user.Username,
		&user.DisplayName,
		&user.PasswordHash,
		&user.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &user, nil
}

func (r *UserRepository) UsernameExists(ctx context.Context, username string) (bool, error) {
	query := `SELECT EXISTS(SELECT 1 FROM users WHERE username = $1);`
	var exists bool
	err := config.DB.QueryRow(ctx, query, username).Scan(&exists)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}
	return exists, nil
}

func (r *UserRepository) FindByUsername(ctx context.Context, username string) (*models.User, error) {
	query := `
		SELECT id, username, display_name, password_hash, created_at 
		FROM users 
		WHERE username = $1;
	`
	var user models.User
	err := config.DB.QueryRow(ctx, query, username).Scan(
		&user.ID,
		&user.Username,
		&user.DisplayName,
		&user.PasswordHash,
		&user.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &user, nil
}

func (r *UserRepository) SearchUsers(ctx context.Context, searchTerm string, limit, offset int) ([]models.User, error) {
	pattern := "%" + searchTerm + "%"
	query := `
		SELECT id, username, display_name, created_at
		FROM users
		WHERE username ILIKE $1 OR display_name ILIKE $2
		ORDER BY username ASC
		LIMIT $3 OFFSET $4;
	`
	rows, err := config.DB.Query(ctx, query, pattern, pattern, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []models.User = []models.User{}
	for rows.Next() {
		var u models.User
		err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.CreatedAt)
		if err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	return users, nil
}

func (r *UserRepository) FindByID(ctx context.Context, id string) (*models.User, error) {
	query := `
		SELECT id, username, display_name, created_at 
		FROM users 
		WHERE id = $1;
	`
	var user models.User
	err := config.DB.QueryRow(ctx, query, id).Scan(
		&user.ID,
		&user.Username,
		&user.DisplayName,
		&user.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &user, nil
}

func (r *UserRepository) FindByProviderID(ctx context.Context, provider, providerID string) (*models.User, error) {
	column := "google_id"
	if provider == "github" {
		column = "github_id"
	}

	query := `
		SELECT id, username, COALESCE(email, ''), display_name, COALESCE(google_id, ''), COALESCE(github_id, ''), created_at
		FROM users 
		WHERE ` + column + ` = $1;
	`
	var u models.User
	err := config.DB.QueryRow(ctx, query, providerID).Scan(&u.ID, &u.Username, &u.Email, &u.DisplayName, &u.GoogleID, &u.GithubID, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (r *UserRepository) FindByEmail(ctx context.Context, email string) (*models.User, error) {
	query := `
		SELECT id, username, COALESCE(email, ''), display_name, COALESCE(google_id, ''), COALESCE(github_id, ''), created_at
		FROM users 
		WHERE email = $1;
	`
	var u models.User
	err := config.DB.QueryRow(ctx, query, email).Scan(&u.ID, &u.Username, &u.Email, &u.DisplayName, &u.GoogleID, &u.GithubID, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (r *UserRepository) LinkProviderAccount(ctx context.Context, userID, provider, providerID string) error {
	column := "google_id"
	if provider == "github" {
		column = "github_id"
	}

	query := `UPDATE users SET ` + column + ` = $1 WHERE id = $2::uuid;`
	_, err := config.DB.Exec(ctx, query, providerID, userID)
	return err
}

func (r *UserRepository) CreateOAuthUser(ctx context.Context, username, email, displayName, provider, providerID string) (*models.User, error) {
	column := "google_id"
	if provider == "github" {
		column = "github_id"
	}

	query := `
		INSERT INTO users (username, email, display_name, password_hash, ` + column + `, created_at)
		VALUES ($1, $2, $3, 'OAUTH_PASSWORDLESS', $4, NOW())
		RETURNING id, username, COALESCE(email, ''), display_name, created_at;
	`
	var u models.User
	err := config.DB.QueryRow(ctx, query, username, email, displayName, providerID).Scan(&u.ID, &u.Username, &u.Email, &u.DisplayName, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// DeleteUser removes the account. ON DELETE CASCADE removes its messages,
// group memberships, devices, prekeys, refresh tokens and verifications.
func (r *UserRepository) DeleteUser(ctx context.Context, id string) error {
	tag, err := config.DB.Exec(ctx, `DELETE FROM users WHERE id = $1;`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return pgx.ErrNoRows
	}
	return nil
}
