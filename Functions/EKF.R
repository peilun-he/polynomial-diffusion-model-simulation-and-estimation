EKF <- function(par, yt, mats, func_f, func_g, dt, n_coe, noise) {
  # Extended Kalman Filter, for polynomial diffusion model. 
  # Ref: Eric Wan & Rudolph van der Merwe (2000)
  # Non-linear state-space model: 
  #   X_t = f(X_{t-1}) + epsilon_t, epsilon_t ~ N(0, W)
  #   Y_t = g(X_t) + eta_t, eta_t ~ N(0, V)
    
  # Inputs: 
  #   par: a vector of parameters
  #   yt: futures prices
  #   mats: time to maturities
  #   func_f: function f(x), which should take two arguments, xt and a vector of parameters, and return two values, f(x) and f'(x)
  #   func_g: function g(x), which should take three arguments, xt, a vector of parameters and maturities, and return two values, g(x) and g'(x)
  #   dt: delta t
  #   n_coe: the number of model coefficient to be estimated 
  #   noise: Gaussian -> Gaussian noise for both process and measurement noise
  #          Gamma -> Gaussian process noise and Gamma measurement noise
  # Outputs:
  #   nll: negative log-likelihood
  #   ll_table: a vector to store cumulative log-likelihood at each time point - used to calculate Sandwich variance
  #   table_xt_filter: filtered state variable
  #   table_xt_prediction: predicted state variable
  
  x0 <- c( par[length(par)-1], par[length(par)] )
  par <- par[1: (length(par)-2)]
  par_all <- par # model parameters and model coefficients
  par <- par[1: (length(par) - n_coe)] # model parameters
  
  kappa_chi  <- par[1]
  kappa_xi   <- par[2]
  mu_xi      <- par[3]
  sigma_chi  <- par[4]
  sigma_xi   <- par[5]
  rho        <- par[6]
  lambda_chi <- par[7]
  lambda_xi  <- par[8]
  
  n_obs <- dim(yt)[1]
  n_contract <- dim(yt)[2]
  n_state <- 2
  table_xt_filter <- matrix(0, nrow = n_obs, ncol = n_state)  # a_t|t
  table_Pt_filter <- array(0, dim = c(n_state, n_state, n_obs)) # P_t|t
  table_xt_prediction <- matrix(0, nrow = n_obs, ncol = n_state) # a_t|t-1
  table_Pt_prediction <- array(0, dim = c(n_state, n_state, n_obs)) # P_t|t-1
  table_Pyy <- array(0, dim = c(n_contract, n_contract, n_obs)) # Covariance of y
  nll <- 0 # negative log-likelihood
  ll_table <- matrix(0, nrow = 1, ncol = n_obs) 
  
  # Covariance matrices
  if (noise == "Gaussian") {
    if (n_contract == 1) {
      V <- par[length(par)]^2
    } else {
      V <- diag( par[9: length(par)]^2 )
    }
    
    W <- matrix(c(sigma_chi^2/(2*kappa_chi) * ( 1-exp(-2*kappa_chi*dt) ), 
                  rho*sigma_chi*sigma_xi/(kappa_chi+kappa_xi) * ( 1-exp(-(kappa_chi+kappa_xi)*dt) ), 
                  rho*sigma_chi*sigma_xi/(kappa_chi+kappa_xi) * ( 1-exp(-(kappa_chi+kappa_xi)*dt) ), 
                  sigma_xi^2/(2*kappa_xi) * ( 1-exp(-2*kappa_xi*dt) )), 
                nrow = 2, byrow = TRUE)
  } else if (noise == "Gamma") {
    s_sq <- par(9)
    V <- diag(rep(s_sq, n_contract))
    W <- matrix(c(sigma_chi^2/(2*kappa_chi) * ( 1-exp(-2*kappa_chi*dt) ),
                  rho*sigma_chi*sigma_xi/(kappa_chi+kappa_xi) * ( 1-exp(-(kappa_chi+kappa_xi)*dt) ), 
                  rho*sigma_chi*sigma_xi/(kappa_chi+kappa_xi) * ( 1-exp(-(kappa_chi+kappa_xi)*dt) ), 
                  sigma_xi^2/(2*kappa_xi) * ( 1-exp(-2*kappa_xi*dt) )), 
                nrow = 2, byrow = TRUE)
  } else {
    stop("Incorrect distribution of noises. ")
  }
  
  # Initialization
  # xt_filter <- c( 0, mu_xi / kappa_xi ) # x_0|0
  xt_filter <- x0
  Pt_filter <- matrix(c(sigma_chi^2 / (2*kappa_chi), 
                        sigma_chi*sigma_xi*rho / (kappa_chi + kappa_xi), 
                        sigma_chi*sigma_xi*rho / (kappa_chi + kappa_xi), 
                        sigma_xi^2 / (2*kappa_xi)), 
                      nrow = 2, byrow = TRUE) # P_0|0
  
  for (i in 1: n_obs) {
    # Prediction step
    temp <- func_f(xt_filter, par)
    xt_prediction <- temp$y
    jacobian_state <- temp$y_jacobian # the jacobian of state function
    Pt_prediction <- jacobian_state %*% Pt_filter %*% t(jacobian_state) + W
    temp <- func_g(xt_prediction, par_all, matrix(mats[i, ], nrow = 1))
    yt_prediction <- temp$y
    jacobian_measurement <- temp$y_jacobian # the jacobian of measurement function
      
    # Filter step
    Pxy <- Pt_prediction %*% t(jacobian_measurement)
    Pyy <- jacobian_measurement %*% Pt_prediction %*% t(jacobian_measurement) + V
    K <- Pxy %*% solve(Pyy)  
    et <- yt[i, ] - yt_prediction
    xt_filter <- xt_prediction + K %*% t(et)
    Pt_filter <- (diag(2) - K %*% jacobian_measurement) %*% Pt_prediction
    #Pt_filter <- (diag(2) - K %*% jacobian_measurement) %*% Pt_prediction %*% t(diag(2) - K %*% jacobian_measurement) + K %*% V %*% t(K) # Joseph covariance update    
    
    # Update tables
    table_xt_filter[i, ] <- xt_filter
    table_xt_prediction[i, ] <- xt_prediction
    table_Pt_filter[, , i] <- Pt_filter
    table_Pt_prediction[, , i] <- Pt_prediction
    table_Pyy[, , i] <- Pyy
    
    if (det(Pyy)<0) {
      message("matrix is not semi positive definite (EKF)")
    }
  
    # Update likelihood 
    nll <- nll + 0.5*length(yt[i, ])*log(2*pi) + 0.5*log(det(Pyy)) + 0.5*et %*% solve(Pyy) %*% t(et)
    ll_table[i] <- -(0.5*length(yt[i, ])*log(2*pi) + 0.5*log(det(Pyy)) + 0.5*et %*% solve(Pyy) %*% t(et))
  }
  return(list(nll = nll, 
              ll_table = ll_table, 
              xt_filter = table_xt_filter, 
              Pt_filter = table_Pt_filter, 
              xt_prediction = table_xt_prediction, 
              cov_y = table_Pyy))
}




