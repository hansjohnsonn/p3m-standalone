#ifndef EWALD_H
#define EWALD_H

#include "p3m.h"

void Ewald_init(system_t *, p3m_parameters_t *);
void Ewald_k_space(system_t *, p3m_parameters_t *);
void Ewald_compute_influence_function(system_t *, p3m_parameters_t *);
FLOAT_TYPE Ewald_compute_optimal_alpha(system_t *, p3m_parameters_t *);
FLOAT_TYPE Ewald_estimate_error(system_t *, p3m_parameters_t *);

extern const method_t method_ewald;

#endif
